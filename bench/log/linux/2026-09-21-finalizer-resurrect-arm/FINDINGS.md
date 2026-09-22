# `make finalizer-complex` asserts what a finalizer runs on, and can be shown wrong

**Date:** 2026-09-21 · host: Linux 7.0.0-31-generic x86_64 (QEMU), Crystal 1.21.0
Tree `5287375` · `python3 bench/gate_arm_census.py`

Seven phases, every one asserting that a finalizer *ran* (or a link
cleared). None asserted what it ran on, and that is the half with a
history: `enqueue_unreachable_finalizers` marks a queued object so the
sweep leaves it for `run_pending` — the Boehm rule — because before it
`Socket#finalize` ran on freed memory (the acik wrk SEGV). Nothing in the
tree required that mark.

## What changed

- `Heap#finalizer_resurrect` (default true), `GCRY_FINALIZER_NO_RESURRECT=1`
  for the process heap. Off, the queued object is not marked, the sweep
  reclaims it, and the callback runs on a swept block.
- Phase 0 in `bench/finalizer_complex.cr`: the callback asks `heap.live?(ptr)`
  at the moment it runs. Shipped requires allocated; `--broken` sets the
  property off, runs phase 0 alone and requires swept.
- Recipe runs both; the CI step goes through the recipe (the sound suite
  reuses the binary it builds).

## Measured

| arm | phase 0 | verdict |
|---|---|---|
| shipped | allocated | 9 passed, 0 failed |
| `--broken` | swept | 1 passed, 0 failed |
| resurrection dropped, shipped | swept | **FAIL** — and phases 1–7 all still pass |
| property's effect dropped, `--broken` | allocated | **FAIL** |

The third row is the point: with the Boehm rule removed the seven
pre-existing phases stay green on a freed block. "Ran" does not
discriminate; "ran on what" does.

## Census

```
harness-driven gates:              100
red direction constructed per run: 78
red direction established by hand: 22
```

**100 / 77 / 23 → 100 / 78 / 22.** Recipe 1 (`--broken`). Still owed an
arm: `compiler-gc-contract`, `oom-test`(+short), `thread-storm`(+short).
