# `make segv-region-report` forks the mapping line's absence

**Date:** 2026-09-20 · host: Linux 7.0.0-31-generic x86_64 · Crystal 1.21.0
Tree `35e001f` · `python3 bench/gate_arm_census.py`

The leftover-41 note after the mark-clear arm named two CI gaps that are
research harnesses by design (`nested-spawn-uaf`, `occupied-release`).
Of the rest that actually run in CI, `segv-region-report` is the one
whose rot is an anonymous crash: the 2026-09-19 churn sighting was
`SIGSEGV at 0x55816aff0` and "never a gcry allocation", 1 of 24 children,
nothing to compare with the next one. The gate already forked three
faults and checked the numbers. The census still counted it "by hand,
once" because the only way it came out red was a hand edit of
`report_faulting_region`. Another pass on the detector would have
counted the children dying — they are the subject, not a broken
collector. The next arm, not another pass.

## What changed

`GCRY_DISABLE_REGION_REPORT=1` skips `report_faulting_region`. The flag
is a class variable set from `apply_env_config`, not an `ENV` read in
the handler. The parent already forked `mapped` / `file` / `wild`; it
now forks the same three under the knob and requires each *not* to name
the mapping. The rest of the report still prints — "never a gcry
allocation" is what the pre-fix sighting carried.

## Measured

| arm | mapping line | notes |
|---|---|---|
| shipped `mapped` | **yes** — `[0x2a0000000000, 0x2a0000100000) ---p, 1048576 bytes, 0xfedcc below its top, anonymous` | child faulted at `0x2a0000001234` |
| shipped `file` | **yes** — same size, named `/home/naruto/playground/gcry/bin/segv_region_report` | |
| shipped `wild` | **yes** — `no mapping holds that address` | |
| `GCRY_DISABLE_REGION_REPORT=1 mapped` | **none** (count 0) | same `never a gcry allocation` line, then the writer frames |
| full gate (6 children) | 3 named, 3 unnamed | 0.01 s; `make` 3.32 s including the compile |
| full gate with the env hash emptied | 3 named on the disable half | **FAIL**, 3 arms, 0.01 s |

Dropping `GCRY_DISABLE_REGION_REPORT` from the parent's env hash reddens
the gate. Putting it back restores 3/3 unnamed.

## Census

```
harness-driven gates:              99
red direction constructed per run: 59
red direction established by hand: 40
prose claims of a hand break:      19 (nothing re-checks these)
```

**99 / 58 / 41 → 99 / 59 / 40.** `segv-region-report` moved: recipe 0,
harness 1. The recipe is unchanged; the harness now has
`"GCRY_\w+" =>`.

Still a real gap, in CI: `nested-spawn-uaf` (the original repro;
`dead-stack-root` is the gate), `occupied-release` (recipe prefixes
both arms with `-`).
