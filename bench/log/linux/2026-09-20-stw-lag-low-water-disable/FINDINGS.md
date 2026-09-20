# `make stw-lag-pause` turns the skip off a hand edit used to gate

**Date:** 2026-09-20 · host: Linux 7.0.0-31-generic x86_64 · Crystal 1.21.0
Tree `4b562fa` · `python3 bench/gate_arm_census.py`

The leftover-37 note after the pool-index arm still named two research
harnesses by design (`nested-spawn-uaf`, `occupied-release`). Of the
rest that actually run in CI, `stw-lag-pause` is the one whose skip
could rot in silence: `--dirty-kb=16` already requires the default
path to skip, but `GCRY_STACK_LOW_WATER=0` was read by `src/` and
appeared in no recipe. The census still counted the gate "by hand,
once".

## What changed

`GCRY_STACK_LOW_WATER=0` already sets `heap.stack_low_water_scan =
false`. `--disabled` requires every config at 0 skips. Dropping the
assignment while leaving the knob and the flag set reddens the gate
rather than hiding it (exit 64: the skip is still on).

## Measured

| arm | tuned skips (median) | stack_lag0 / sound pause | notes |
|---|---|---|---|
| `--dirty-kb=16` | **34** | 14.47 / 23.05 ms (1.01× / 1.61×) | 0.9 s, skip on |
| `GCRY_STACK_LOW_WATER=0 --disabled` | **0** | 329.19 / 340.37 ms (**14.63× / 15.12×**) | 2.4 s, skip off |
| `--disabled` with no knob | — | — | exit **64**, guard |
| `--disabled` with the assignment dropped | — | — | exit **64**, 0.0 s |

The 14× is the skip's own number, not a pause budget: lag 0 without it
scans the full parked-fiber span. The ratio bound relaxes to
`--max-ratio-nolw` when the skip is off, so the counter is the gate.

## Census

```
harness-driven gates:              99
red direction constructed per run: 63
red direction established by hand: 36
prose claims of a hand break:      19 (nothing re-checks these)
```

**99 / 62 / 37 → 99 / 63 / 36.** `stw-lag-pause` moved: recipe 1,
harness 0. The recipe now has `GCRY_STACK_LOW_WATER=0` and `--disabled`.

Still a real gap, in CI: `nested-spawn-uaf` (the original repro;
`dead-stack-root` is the gate), `occupied-release` (recipe prefixes
both arms with `-`).
