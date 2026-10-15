# Upstream draft: `raises?` is not a fixpoint, so a `rescue` can be skipped

Prepared 2026-10-14 against crystal-lang/crystal master `39f3f4d` (1.22.0).
Not filed. `crystal-raises-fixpoint.patch` (this directory) applies to it
unchanged.

## Issue

**Title:** `rescue` does not catch an exception raised through a call cycle
(`raises?` not propagated)

With the stock compiler and no shards, this program prints
`Unhandled exception: boom` instead of `rescued` (`min.cr`):

```crystal
def s3(n)
  helper(n)          # s3 → helper → s2 → s3, before s3's raise
  raise "boom" if n == 0
  n
end

def helper(n)
  s2(n + 1) if n > 100
end

def s2(n)
  s3(n)
end

s3(1)                # makes the cleanup pass reach s3 first
begin
  s2(0)
  puts "not raised"
rescue
  puts "rescued"
end
```

Stdlib code hits it too, depending on what else the program calls
(`stock_boehm.cr`, stock 1.21.0, Boehm):

```crystal
begin
  5.clamp(...3)      # Unhandled exception: Can't clamp an exclusive range
rescue e
  puts "ok"
end
```

**Why.** Codegen emits `invoke` with a landing pad only when the target's
`raises?` is true (`codegen/call.cr`), otherwise a plain `call`, which an
exception unwinds straight through. `CleanupTransformer#transform(Call)`
copies `raises?` from callee to caller once, when it reaches the call. A
callee reached again through a call cycle is still being transformed; if its
own `raise` comes after the cycle in its body, its flag is still false at
that moment, and every caller on the cycle keeps `raises? == false` for good.

Instrumenting the pass (`crystal-raises-trace.patch`) counts the callers left
this way: 15 in the `min.cr` program on Boehm, 0 with the fix below.

## PR

**Title:** Fix `raises?` not propagated through call cycles

`transform(Call)` records each caller → callee edge whose callee did not
raise yet when the call was reached. After `cleanup_types`,
`propagate_raises` pushes `raises?` along those edges until nothing changes
(a worklist over callees that ended up raising). The cost is one hash entry
per such edge during the cleanup pass.

Adds the codegen spec "rescues from a method that only raises through a call
cycle". Fixes #<issue>.

Verified on `39f3f4d` with the 1.21.0 compiler: with the fix,
`spec/compiler/codegen/exception_spec.cr` 73 examples, 0 failures; without
it, the new example errors: the program dies with the unhandled exception.
The full compiler suite has not been run against the patch locally; CI will.
