# What starting the Nth thread costs: the Linux baseline

**Date:** 2026-09-17 · host: AMD Ryzen AI 9 465 (Zen 5, 20 threads), Linux 7.2.4
Tree `17e4a2d` · Crystal 1.21.0 · `bench/thread_startup_cost.cr`

This probe exists because of a CI accident rather than a design.
`bench/stack_bounds_growth.cr` asked for 100 live threads; the macOS runner
never got all 100 *running* inside 120 s, twice, while the 8-thread arm was
instantaneous (`../2026-09-16-stack-bounds-gate/`). `threads held: 100` never
printed, so the time went into thread **startup**. The hypothesis `ROADMAP.md`
carries: `Thread.new` allocates, an allocation can trigger a collection, and
Darwin suspends **each** thread with its own Mach `thread_suspend` /
`thread_get_state` pair where Linux broadcasts one signal — so a
thread-creation storm would pay O(n) per collection and O(n²) over the storm
there and not here.

This file is the Linux half. The Darwin half is a CI probe step; the answer is
its log.

## Linux

| arm | n | ready_ms | join_ms | µs/thread | collections |
|---|---|---|---|---|---|
| auto=on | 8 | 1.4 | 24.2 | 178.4 | **0** |
| auto=on | 32 | 2.1 | 24.0 | 66.7 | **0** |
| auto=on | 64 | 1.9 | 25.0 | 30.4 | **0** |
| auto=on | 100 | 2.8 | 25.0 | 27.7 | **0** |
| auto=off | 8 | 1.3 | 24.3 | 161.1 | 0 |
| auto=off | 100 | 2.8 | 25.0 | 28.4 | 0 |
| collect | 8 | 31.6 | 349.0 | 3952.3 | 12 |
| collect | 32 | 65.1 | 253.9 | 2035.4 | 12 |
| collect | 64 | 41.3 | 256.7 | 645.9 | 12 |
| collect | 100 | 85.7 | 2859.9 | 857.3 | 11 |

- **100 threads reach running in 2.8 ms.** Against >120 s on the macOS runner
  for the same count, which is the discrepancy this is a baseline for.
- **Per-thread cost falls with n on every arm** — ×0.16, ×0.18, ×0.22 from n=8
  to n=100. Fixed startup overhead amortising, not a product. Nothing quadratic
  on Linux.
- **A collection during the storm costs about 30× per thread** (3952 against
  178 at n=8, 857 against 27.7 at n=100) and the collect arm's `ready_ms` rises
  31.6 → 85.7 ms for a roughly constant ~12 collections, i.e. about 2.6 → 7 ms
  per collection as the live thread count goes 8 → 100. That is the O(n) per
  collection any stop-the-world owes; the open question is Darwin's constant.
- `join_ms` in the collect arm at n=100 is **2.9 s** — releasing and joining 100
  threads while a collector thread runs flat out. Reported because it is the
  largest number here and it is not the thing being measured.

## The first two arms could not test the hypothesis, and that is why there are three

`auto=on` and `auto=off` both report **`collections=0`**: 100 `Thread.new` calls
do not allocate their way to the threshold, so the knob that separates the arms
is never exercised and the two rows are the same measurement twice. The
prediction is specifically about collections *during* the storm, so one arm has
to force them — `collect` runs a dedicated thread calling `GC.collect` every
2 ms for the storm's duration, and it is the only arm that bears on the
question.

Reading the first two arms as evidence would have been the failure mode this
whole line of work is about: an arm whose knob does nothing, reported as a
result.

## Shape

Every (arm, n) pair is its own `BoundedChild`. The ancestor of this probe swept
inside one child, so the large-N hang lost the small-N data — exactly the case
under investigation. A pair that outlives its budget prints `TIMEOUT` and the
sweep continues; the probe fails only if **no** pair produced a datum, because
"no signal" from a probe that never ran is the one reading that must not pass.

It is a probe and not a gate: it asserts nothing about the numbers. On Darwin it
runs `continue-on-error`, and its evidence is the log rather than its step
conclusion — the distinction that cost a wasted measurement on 2026-09-17,
when `timeout 180` on a macOS runner exited 127 in 0 s and was reported green.
