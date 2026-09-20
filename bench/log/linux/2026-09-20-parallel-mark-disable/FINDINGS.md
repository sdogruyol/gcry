# `make parallel-mark-process` skips the steal a hand edit used to zero

**Date:** 2026-09-20 · host: Linux 7.0.0-31-generic x86_64 · Crystal 1.21.0
Tree `03af297` · `python3 bench/gate_arm_census.py`

The leftover-39 note after the holders-find arm still named two CI gaps
that are research harnesses by design (`nested-spawn-uaf`,
`occupied-release`). Of the rest that actually run in CI,
`parallel-mark-process` is the one whose rot is a silent steal: four
workers configured, `parallel_mark_stolen` never asked to stay at 0, so
the only way the gate came out red was a hand edit of that counter. The
census still counted it "by hand, once". Chain integrity is unchanged.

## What changed

`GCRY_DISABLE_PARALLEL_MARK=1` pins `parallel_mark_workers` at 1 even if
a later assignment asks for 4. The flag is a heap field set from
`apply_env_config`, not an `ENV` read in the setter. `--disabled`
requires workers stay 1 and stolen stay 0, and still requires the 200
000-node chain to be whole. Dropping the skip while leaving the knob
and the flag set reddens the gate rather than hiding it.

## Measured

| arm | workers | runs | stolen | chain | notes |
|---|---|---|---|---|---|
| shipped | **4** | 0→5 | 0→460024 | 200000 | 3.09 s |
| `GCRY_DISABLE_PARALLEL_MARK=1 --disabled` | **1** | 0→0 | **0→0** | 200000 | 0.46 s |
| `--disabled` with no knob | — | — | — | — | exit **64**, guard |
| `--disabled` with the pin dropped | **4** | — | — | — | **FAIL** workers=4, 0.00 s |

Dropping `@force_serial_mark ? 1` from `parallel_mark_workers=` reddens
the `--disabled` arm (workers become 4 before the chain is built).
Putting it back restores workers=1, stolen=0. `make parallel-mark-process`
5.15 s both arms, compile included. Stolen on a second shipped run was
525395 — the assertion is rise, not a count.

## Census

```
harness-driven gates:              99
red direction constructed per run: 61
red direction established by hand: 38
prose claims of a hand break:      19 (nothing re-checks these)
```

**99 / 60 / 39 → 99 / 61 / 38.** `parallel-mark-process` moved: recipe 1,
harness 0. The recipe now has `GCRY_DISABLE_PARALLEL_MARK=1` and
`--disabled`.

Still a real gap, in CI: `nested-spawn-uaf` (the original repro;
`dead-stack-root` is the gate), `occupied-release` (recipe prefixes
both arms with `-`).
