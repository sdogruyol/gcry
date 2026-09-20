# `make mark-clear-index` forks children under the knobs `--control` hid

**Date:** 2026-09-20 · host: Linux 7.0.0-31-generic x86_64 · Crystal 1.21.0
Tree `6b2f838` · `python3 bench/gate_arm_census.py`

The leftover-42 note after the BoundedChild detector pass named three
CI gaps whose red direction was a hand edit or a swallowed exit.
`mark-clear-index` was the first: it already forked, already required
residue, and the census still counted it "by hand, once" because the
defect arm was named `--control`. `--control` is excluded by design —
a control has to pass. Another pass on the detector would have counted
this one by loosening that rule. The next arm, not another pass.

The knobs were already there. `GCRY_MARK_CLEAR_LIST=1` restores the
list walk; `GCRY_SWEEP_MUTATOR_LATCH=0` restores the pre-fix mutator
count reads. `thread-churn-uaf --control` sets both. This gate set the
same two properties in-process from ARGV, so dropping the knobs would
have left the arm green.

## What changed

`--control` is the parent. It forks `--child` under

```
GCRY_MARK_CLEAR_LIST=1
GCRY_SWEEP_MUTATOR_LATCH=0
GCRY_MARK_CLEAR_AUDIT=1
GCRY_CHUNK_LIST_AUDIT=1
```

The child does not assign `mark_clear_list` or `sweep_mutator_latch`.
`apply_env_config` does. The audits are how residue and offlist become
numbers rather than a silent pass.

## Measured

| arm | residue | offlist | crash | clean | notes |
|---|---|---|---|---|---|
| shipped (240 rounds) | 0 | 0 | — | — | 1.3 s |
| `--control` (6 children, knobs) | **6** | 0 | 0 | 0 | 0.6 s; every child broke on residue |
| one `--child` with knobs | **4** | 56 | 0 | — | collection 34; first missed chunk `0x75892a480000` |
| one `--child`, audits only | 0 | 0 | 0 | — | 9.3 s, full 1920-round cap |
| `--control` with knobs dropped | 0 | 0 | 0 | **6** | FAIL, 42.8 s |

The audits-only child is the shipped clear under the broken arm's
workload: zero residue, so the 6/6 is the knobs, not the churn. Dropping
`GCRY_MARK_CLEAR_LIST` and `GCRY_SWEEP_MUTATOR_LATCH` from the parent's
env hash reddens the gate. Putting them back restores 6/6.

## Census

```
harness-driven gates:              99
red direction constructed per run: 58
red direction established by hand: 41
prose claims of a hand break:      19 (nothing re-checks these)
```

**99 / 57 / 42 → 99 / 58 / 41.** `mark-clear-index` moved: recipe 0,
harness 1. The recipe still says `--control`; the harness now has
`"GCRY_\w+" =>` and `--child`.

Still a real gap, in CI: `nested-spawn-uaf` (the original repro;
`dead-stack-root` is the gate), `occupied-release` (recipe prefixes
both arms with `-`).
