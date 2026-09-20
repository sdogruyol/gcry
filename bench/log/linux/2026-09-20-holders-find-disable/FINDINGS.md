# `make holders-find` skips the walk a hand edit used to drop

**Date:** 2026-09-20 · host: Linux 7.0.0-31-generic x86_64 · Crystal 1.21.0
Tree `9c264bc` · `python3 bench/gate_arm_census.py`

The leftover-40 note after the mapping-line arm still named two CI gaps
that are research harnesses by design (`nested-spawn-uaf`,
`occupied-release`). Of the rest that actually run in CI, `holders-find`
is the one whose rot is a silent search: a 2026-09-12 report printed
"holders — none" next to a live marked array that held the address at
offset 16. The gate already planted three holders and required a count.
The census still counted it "by hand, once" because the only way it came
out red was a hand edit of `count_heap_holders`. The crash-time search
is unchanged.

## What changed

`GCRY_DISABLE_HOLDERS_FIND=1` skips `heap_holders_count`. The flag is a
class variable set from `apply_env_config`, not an `ENV` read in the
walk. `--disabled` requires each planted target at 0 and still requires
the masked control at 0. Dropping the skip while leaving the knob and
the flag set reddens the gate rather than hiding it.

## Measured

| arm | small | medium | large | control | notes |
|---|---|---|---|---|---|
| shipped | **1** | **1** | **1** | 0 | 4.5 s `make`, compile included |
| `GCRY_DISABLE_HOLDERS_FIND=1 --disabled` | **0** | **0** | **0** | 0 | skip engaged |
| `--disabled` with no knob | — | — | — | — | exit **64**, guard |
| `--disabled` with the skip line dropped | **1** | **1** | **1** | — | **FAIL** 3 of 3, 0.01 s |

Dropping `@@skip_heap_count` from `heap_holders_count` reddens the
`--disabled` arm. Putting it back restores 3/3 unfound.

## Census

```
harness-driven gates:              99
red direction constructed per run: 60
red direction established by hand: 39
prose claims of a hand break:      19 (nothing re-checks these)
```

**99 / 59 / 40 → 99 / 60 / 39.** `holders-find` moved: recipe 1,
harness 0. The recipe now has `GCRY_DISABLE_HOLDERS_FIND=1` and
`--disabled`.

Still a real gap, in CI: `nested-spawn-uaf` (the original repro;
`dead-stack-root` is the gate), `occupied-release` (recipe prefixes
both arms with `-`).
