# `make pool-refill-cost` skips the index a hand edit used to drop

**Date:** 2026-09-20 · host: Linux 7.0.0-31-generic x86_64 · Crystal 1.21.0
Tree `1f98548` · `python3 bench/gate_arm_census.py`

The leftover-38 note after the parallel-mark arm still named two CI gaps
that are research harnesses by design (`nested-spawn-uaf`,
`occupied-release`). Of the rest that actually run in CI,
`pool-refill-cost` is the one whose rot is a silent walk: 2.0 rebuilds
per collection is the per-version floor, and the only way the gate came
out red was a hand edit of that threshold. The census still counted it
"by hand, once".

## What changed

`GCRY_DISABLE_POOL_INDEX=1` treats the available-chunk index as invalid
on every `bitmap_take_pool_chunk`, so each refill walks the class again.
The flag is a heap field set from `apply_env_config`, not an `ENV` read
in the take. `--disabled` requires rebuilds per collection above 8.
Dropping the skip while leaving the knob and the flag set reddens the
gate rather than hiding it.

## Measured

| arm | rebuilds / collection | notes |
|---|---|---|
| shipped | **2.0** | 0.73 s, 80 rebuilds per phase |
| `--churn` | **2.0** | 0.16 s |
| `GCRY_DISABLE_POOL_INDEX=1 --disabled` | **12.25** | 0.73 s, 480–520 rebuilds per phase |
| `--disabled` with no knob | — | exit **64**, guard |
| `--disabled` with the skip line dropped | **2.0** | **FAIL**, 0.73 s |

Dropping `pool.value.valid = false if @pool_index_disabled` reddens the
`--disabled` arm. Putting it back restores 12.25.

## Census

```
harness-driven gates:              99
red direction constructed per run: 62
red direction established by hand: 37
prose claims of a hand break:      19 (nothing re-checks these)
```

**99 / 61 / 38 → 99 / 62 / 37.** `pool-refill-cost` moved: recipe 1,
harness 0. The recipe now has `GCRY_DISABLE_POOL_INDEX=1` and
`--disabled`.

Still a real gap, in CI: `nested-spawn-uaf` (the original repro;
`dead-stack-root` is the gate), `occupied-release` (recipe prefixes
both arms with `-`).
