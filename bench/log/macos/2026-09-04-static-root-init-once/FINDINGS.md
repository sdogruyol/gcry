# Why `GC.init`'s static-root resolve crashed macOS before `main`

**Status: attributed and fixed. The mechanism is `once`-guarded lazy
class-variable initialisation reached from `GC.init`, which runs before
`Crystal.main` calls `init_runtime`. Two class variables in
`src/gcry/platform/darwin_roots.cr` had initialisers the compiler wraps in
`__crystal_once`; neither needed one. `crystal spec -Dgc_none process_spec`
and `samples/min.cr` both pass with the eager resolve on.**

Apple M2 Pro, Darwin 25.6.0 / macOS 26.6.2 arm64, Crystal 1.21.0 (LLVM 15.0.7),
at `18d74c8` plus this branch.

## What was open

`src/gcry/gc_override.cr` carried the eager resolve behind `{% if
flag?(:linux) %}`. Removing that guard took `crystal spec -Dgc_none
process_spec` on the macOS runner to "Process terminated because of an invalid
memory access" (CI run 33900305015, job `test (darwin native)`) while every
Linux job stayed green. With no Darwin host the guard went back, and the cost
was recorded in ROADMAP: `ensure_static_root_cache` stayed reachable only from
`scan_static_roots`, i.e. from **inside** the first stopped world, where
`push_range` called `LibC.realloc`.

## Reproduction

Three lines of user code are enough. `samples/min.cr`:

```
$ crystal build -Dgc_none samples/min.cr -o /tmp/min && /tmp/min
$ echo $?
139
```

So this is not a spec-harness interaction. It is every `-Dgc_none` binary.

## Attribution

`lldb -b -o run -o bt`, on a `--debug` build:

```
frame #0: push(self=0x0000000000000000, node=0x…) at thread_linked_list.cr:38
frame #1: initialize(self=…, stack=…, thread=…)   at fiber.cr:157
frame #2: new(stack=…, thread=…)                  at fiber.cr:135
frame #3: initialize(self=…)                      at thread.cr:155
frame #4: new                                     at thread.cr:152
frame #5: current_thread                          at pthread.cr:65
frame #6: current                                 at thread.cr:214
frame #7: current                                 at fiber.cr:209
frame #8: once(flag=…, initializer=…)             at once.cr:85
frame #9: __crystal_once(flag=…, initializer=…)   at once.cr:124
frame #10: ~Gcry::Platform::cached_generation:read at darwin_roots.cr:11
frame #11: ensure_static_root_cache                at darwin_roots.cr:11
frame #12: apply_env_config(heap=…)                at gc_override.cr:815
frame #13: init                                    at gc_override.cr:194
frame #14: main(argc=1, argv=…)                    at main.cr:38
```

`EXC_BAD_ACCESS (code=1, address=0x18)`: a null `Thread::LinkedList` receiver,
`0x18` being its `@mutex` offset. `Fiber.@@fibers` is `uninitialized` and is
assigned by `Fiber.init`, which `Crystal.main` calls from `init_runtime` —
**after** `GC.init` (`main.cr:38` then `main.cr:40`). The stdlib says so in a
comment right above it:

> `__crystal_once` directly or indirectly depends on `Fiber` and `Thread` so we
> explicitly initialize their class vars, then init crystal/once

## Which declarations, and why only those

`crystal build -Dgc_none --emit llvm-ir samples/min.cr`, then grepping the
emitted module:

| declaration | initialiser kind | accessor emitted |
|---|---|---|
| `@@ranges : RootRange* = Pointer(RootRange).null` | call | `~ranges:read` → `__crystal_once` |
| `@@cached_generation = UInt32::MAX` | constant path | `~cached_generation:read` → `__crystal_once` |
| `@@range_count = 0` | simple literal | none — direct global load |
| `@@range_cap = 0` | simple literal | none |
| `@@maps_generation = 0_u32` | simple literal | none |

and the accessor for `cached_generation` was the **first instruction** of
`ensure_static_root_cache`:

```llvm
entry:
  %0 = call ptr @"~Gcry::Platform::cached_generation:read"()
  %1 = load i32, ptr %0, align 4
  %2 = load i32, ptr @"Gcry::Platform::maps_generation", align 4
```

The guard was protecting a store that changes nothing. The compiler had
already folded both values into the globals' own initialisers —

```llvm
@"Gcry::Platform::cached_generation" = internal global i32 -1
@"Gcry::Platform::ranges"            = internal global ptr null
```

— so the `once`-guarded initialiser would have written `-1` over `-1` and
`null` over `null`. The crash is entirely the cost of asking.

`src/gcry/platform/linux_roots.cr` escaped this by style, not by design:
`@@ranges = uninitialized StaticArray(...)` and every other class variable
there is a simple literal. `src/gcry/platform/linux_stw.cr:73` already records
the same mechanism for a class-var `Atomic.new` — so this was a known trap that
the Darwin file had walked into.

## Fix

Declarations only. `@@ranges` became `uninitialized`, `@@cached_generation` a
literal `4294967295_u32`. Nothing about the resolve logic changed.

While there, `push_range`'s `LibC.realloc` was replaced with the fixed
`StaticArray(RootRange, MAX_RANGES)` Linux uses. That was not cosmetic: the
failure branch read `raise OutOfMemoryError.new(...)`, and an
`OutOfMemoryError.new` inside `GC.init` reaches `__crystal_malloc64` →
`Gcry::Trace::alloc_tick`, another `once`. The realloc also took the malloc
arena on a path that now runs before the runtime exists.

## Gates

`make darwin-static-root-init`, four arms:

| arm | reading |
|---|---|
| ir-green | no `__crystal_once` reachable from `ensure_static_root_cache` on any returning path |
| ir-red | `-Dgcry_static_root_once` puts the edge back, 3 hops via `~cached_generation:read` |
| run-green | `exit=0` |
| run-red | `signal=SEGV` |

The IR walk excludes **panic doors** — `__crystal_raise*`, `__crystal_malloc*`
and every `:NoReturn` function — and that exclusion is load-bearing rather than
convenient. Every Crystal `Int32#+` compiles to `__crystal_raise_overflow` and
every `StaticArray#[]` to `raise<IndexError>`, and both of those reach a
`once`-guarded trace counter through the exception machinery. Without the
exclusion the invariant is unsatisfiable; with anything more excluded it has no
teeth. Measured before the exclusion was written, on the fixed tree:

```
-> ensure_static_root_cache
-> __crystal_raise_overflow
-> OverflowError::new
-> __crystal_malloc64  ->  GC::malloc  ->  Heap#malloc
-> Trace::after_malloc  ->  ~Trace::alloc_tick:read  ->  __crystal_once
```

`make darwin-static-root-init` also runs the effect arm:

| arm | resolves at start of user code | collections at start |
|---|---|---|
| default | 1 | 0 |
| `GCRY_STATIC_ROOT_LAZY=1 --lazy` | 0 (reaches 1 after the first collect) | 0 |

`resolves >= 1` with `collections == 0` is the discriminator: every later
vantage point reads the same value whichever way the resolve happened, so the
counter has to be read before anything else runs. `static_root_bytes` at that
point is 480682 on `samples/min.cr`-sized binaries and 0 on the lazy arm.

## Note for the next reader

`bench/darwin_static_root_init.cr` reads the counters into **local variables**,
not constants. A constant initialiser is `once`-guarded and therefore runs at
its first *read*, which would have been several allocations later — the same
mechanism this whole file is about.
