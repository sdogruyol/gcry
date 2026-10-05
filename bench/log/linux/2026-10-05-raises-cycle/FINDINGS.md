# A `rescue` that never runs: Crystal's `raises?` is not a fixpoint

`docs/DEFAULT-GC-READINESS.md` E3: under gcry, `String.new(Pointer(UInt8).null, 3)`
raised past every `rescue`. Boehm builds and `-Dgc_none` builds without gcry
caught the error. Crystal 1.21.0 (`57cf7da50`), Linux x86_64.

## The mechanism

The codegen emits `invoke` with a landing pad only when the target method's
`raises?` is true (`codegen/call.cr:511`). Otherwise it emits a plain `call`,
and an exception raised below that call unwinds straight through the
surrounding `rescue`.

`raises?` is set from `@[Raises]`, from casts, and in
`CleanupTransformer#transform(Call)`, which copies it from callee to caller
once, when it reaches the call (`semantic/cleanup_transformer.cr:607-609`).
A callee reached again through a call cycle is still being transformed. If its
own `raise` comes after the cycle in its body, its flag is still false at that
moment. Every caller on the cycle then keeps `raises? == false` for good:
nothing revisits them.

The bug is in the compiler, not in gcry. A plain program reproduces it with
the stock compiler and no stdlib involved (`min.cr`):

```crystal
def s3(n)
  helper(n)          # s3 → helper → s2 → s3, before s3's raise
  raise "boom" if n == 0
  n
end
def helper(n); s2(n + 1) if n > 100; end
def s2(n); s3(n); end

s3(1)                # transforms s3 first
begin
  s2(0)
rescue
  puts "rescued"     # stock 1.21.0: "Unhandled exception: boom"
end
```

Stock Boehm programs hit it too. With the stock 1.21.0 compiler and no gcry,
`stock_boehm.cr` does this:

```crystal
begin
  5.clamp(...3)      # Unhandled exception: Can't clamp an exclusive range
rescue e
  puts "ok"
end
```

## What gcry adds

A Boehm backend's `GC.malloc*` bodies are C calls, so the cleanup pass never
walks from an allocation back into Crystal code. gcry's bodies are Crystal, so
explicit stdlib calls such as `String::Builder#initialize` →
`GC.malloc_atomic` and `String::Builder#resize_to_capacity` → `GC.realloc`
lead into the collector and from there back into the stdlib.

The traced cycle for E3, starting at the method still in progress:

```
String.new(Pointer(UInt8), Int32, Int32)      string.cr:233   (in progress; its raise is later)
  String.interpolation …                      "…non-zero (#{bytesize}) bytesize"
  String::Builder#initialize                  → GC.malloc_atomic(UInt32)
  GC.malloc_atomic(UInt64)                    gcry gc_override.cr
  Gcry::Heap#malloc_atomic → Invariant.after_malloc → … (one chain)
  Gcry.default_heap → Heap.new → GC.add_finalizer → Heap#finalize → destroy
    → shutdown_mark_workers → Thread#join (another chain)
  Gcry::Heap#allocate → wait_if_world_stopped_other_thread → Thread.current
    → Thread.new → Thread#stack_address (a third)
  RuntimeError.from_os_error → Errno#message
  String.new(Slice(UInt8))
  String.new(Pointer(UInt8), Int32)           ← left raises? == false
```

Several gcry entry paths close the same cycle. Removing `Heap#finalize` under
`-Dgc_none` cut one of them and the miss stayed, so cutting edges in gcry
does not hold.

## Counting it

`crystal-raises-trace.patch` instruments the cleanup pass. It records every
call edge whose callee was still in progress and not yet raising, and at exit
prints those whose callee ended up raising while the caller did not
(`RAISES-FINAL`). `CRYSTAL_RAISES_TRACE=1` lists them; `=chain` also prints
the in-progress chain. The program is the five-line repro, built
`--no-codegen`.

| Build | Stranded callers |
|-------|-----------------:|
| Boehm, stock pass | 15 (`raises_final_boehm.txt`) |
| gcry, stock pass | 29 (`raises_final_gcry.txt`) |
| gcry + `crystal_raises_compat.cr`, stock pass | 28; `String.new` gone (`raises_final_gcry_workaround.txt`) |
| Boehm or gcry, with `crystal-raises-fixpoint.patch` | 0 |

- **The 14 that gcry adds.** `String.new(Pointer(UInt8), Int32)` is the only
  one user code calls with a reachable raise. The others are `Atomic#get/add/sub`
  instantiations, which raise only for an invalid ordering argument, and two
  gcry internals: `GC.unlock_read` and `Finalizers::Registry#lock_for_stw`.
- **Where they come from.** The list depends on the program: which methods get
  transformed first decides which ones are left stranded. Crystal's std_spec
  GC subset (4364 examples) showed only `String.new`
  (`docs/DEFAULT-GC-READINESS.md` §1).

## Fixes

- **Compiler: `crystal-raises-fixpoint.patch`.** Against 1.21.0. It records
  every caller→callee edge whose callee did not raise when the call was
  reached, and after `cleanup_types` propagates `raises?` along those edges
  until nothing changes (`CleanupTransformer#propagate_raises`).
  - It adds the codegen spec "rescues from a method that only raises through a
    call cycle". With the fix: 73/73 in `spec/compiler/codegen/exception_spec.cr`.
    Without it, the new example errors.
  - With the patched compiler, `min.cr` and `stock_boehm.cr` rescue, and so does
    E3 under unpatched gcry.
  - Only `spec/compiler/codegen/exception_spec.cr` was run, not the full
    compiler suite.
- **gcry, for released compilers: `src/gcry/crystal_raises_compat.cr`.** It
  reopens `String.new(chars : UInt8*, bytesize, size = 0)` with `@[Raises]`.
  The flag is then true from definition time and cannot be stranded. Default
  argument expansions copy it (`semantic/default_arguments.cr:122`).
  - This covers the one user-facing miss found. It is not a general cure: a
    different program can strand a different method.
  - Gate: `process_spec/regression/13_rescue_string_new_null_spec.cr` is red
    without the reopen (1 error) and green with it.

## Not done

- Nothing is filed upstream yet. The patch and `min.cr` are ready for an issue
  and PR against crystal-lang/crystal.
- The full compiler spec suite has not been run against the patch.
