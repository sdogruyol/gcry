# `GC.collect` returned doing nothing again, and the guard was reading a stale owner

**Date:** 2026-09-22 · CI run `35775763860` · host for the local numbers:
Linux 7.0.0-31-generic x86_64 (QEMU), Crystal 1.21.0

`make explicit-collect-barrier` failed on x86_64 CI: the busy arm landed
**19 of 20**. One explicit `GC.collect` returned without a collection
having completed — the exact guarantee that gate was written for, on the
tree that had fixed it.

Rate: **1 failure in 25 CI runs**, **0 in 20 local runs** of the same
binary.

## The window

`Heap#collect`'s guard reads a pair:

```crystal
return if @collecting && (@collect_skip_when_busy ||
                          @collector_pthread == Gcry::Platform.current_thread_id)
```

and `run_collection_body` wrote that pair in this order:

```crystal
@collecting = true
@collector_pthread = Gcry::Platform.current_thread_id
```

Between those two statements `@collecting` is true and
`@collector_pthread` still names **the previous cycle's** collector. A
thread that ran the last collection and asks for one now reads
"collecting, and the owner is me", concludes it is re-entering its own
cycle, and returns — silently, which is the whole defect the guard was
rewritten to remove. In this harness the main thread does exactly that:
it collects, then collects again.

One line wide, and therefore ~1 run in 25 on a 4-vCPU runner and never
on this host.

## The fix

- **Owner, release fence, then flag**, at all three sites that start a
  cycle (`run_collection_body`, the incremental slice, and the
  incremental start). The flag is never true with a stale owner.
- **Acquire fence on the read side**, between `@collecting` and
  `@collector_pthread`: the mirror of the release, so a weakly ordered
  CPU cannot serve the owner from before the writer's store while
  serving the flag from after it.
- **`collect_reentrant_skips`**, counted on that return. It is
  legitimate only for a re-entrant call from a before-collect callback
  or with `GCRY_COLLECT_SKIP_WHEN_BUSY=1`; anywhere else it means a
  caller was told nothing and got nothing.
- The gate asserts it: `reentrant_skips` must be 0 in both shipped arms.
  That is what separates "the guard fired" from "a collection ran and
  moved no counter" — the failing CI run could not say which.

## Verified

| arm | landed | reentrant_skips |
|---|---|---|
| busy, shipped | 20/20 | 0 |
| busy, `GCRY_COLLECT_SKIP_WHEN_BUSY=1` (red arm) | 0/20 | **20** |
| quiet, shipped | 20/20 | 0 |

`crystal spec` 288/0, `process_spec` 32/0, five further repeats of the
gate green.

## The same guard, one method down

`minor_collect` carries a byte-identical guard and was left reading the
pair unordered when `collect` was fixed — the write side is shared and
was already corrected, but a weakly ordered CPU can still misread there,
and a minor that takes that return is as silent as a major that does.
Same treatment: flag, acquire fence, owner, and the return counted in
`collect_reentrant_skips`.

Verified after: `crystal spec` 288/0, `process_spec` 32/0,
`make nursery-bitmap-marks` and `make nursery-tlab-smoke` green (both
drive `minor_collect`), `make explicit-collect-barrier` 4 of 4 arms ok.
