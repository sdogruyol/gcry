# `make fork-test` was not testing atfork

**Date:** 2026-09-20 · host: Linux 7.0.0-31-generic x86_64 · Crystal 1.21.0
Tree `04b6352` · `python3 bench/gate_arm_census.py`

CI's "Fork reinit test" built `bench/fork_reinit.cr` without `-Dwithout_mt`,
called `after_fork_child_reinit` itself, ignored the child's exit status,
and only checked that `malloc_atomic` was non-null. `GCRY_DISABLE_ATFORK`
was documented (`docs/POLICY.md`, `docs/HARDENING.md`) and unused by any
recipe, spec, or CI step. Both a missing handler and a no-op reinit would
have stayed green.

`raise` after fork is not a raise: `check_fork_poison!` is called from
`GC.malloc`, and constructing the exception re-enters malloc. Measured:
stack overflow, 4 s timeout. The poison path now writes through `RawOut`
and `_exit(69)` without allocating.

## What changed

Green builds `-Dwithout_mt`, requires `atfork_installed?`, and the child
mallocs+collects without a manual reinit. `--disabled` is
`GCRY_DISABLE_ATFORK=1`: handler off, `note_fork_child` + malloc must
`_exit(69)`. Dropping the knob reddens the gate (exit 64). Dropping the
`_exit` reddens it (child mallocs, exit 11).

## Measured

| arm | result | notes |
|---|---|---|
| green | **8/8** exit 0 | handler on, child collect kept the pointer |
| `--disabled` | **8/8** exit 0 | stderr poison line, `_exit(69)` |
| `--disabled` without the knob | exit **64** | atfork still installed |
| green with `GCRY_DISABLE_ATFORK=1` | exit **64** | handler off |
| `--disabled` with `_exit` commented | exit **1** | "malloc succeeded after note_fork_child" |
| `--disabled` with `raise` (pre-fix) | stack overflow | 4 s timeout |

## Census

```
harness-driven gates:              99
red direction constructed per run: 65
red direction established by hand: 34
prose claims of a hand break:      19 (nothing re-checks these)
```

**99 / 64 / 35 → 99 / 65 / 34.** `fork-test` moved: recipe 1, harness 0.
The recipe now has `-Dwithout_mt`, `GCRY_DISABLE_ATFORK=1`, and `--disabled`.

Still a real gap, in CI: `nested-spawn-uaf` (the original repro;
`dead-stack-root` is the gate), `occupied-release` (recipe prefixes
both arms with `-`).
