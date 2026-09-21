# `make nested-spawn-uaf` gates, and its fix's disable no longer reddens it

**Date:** 2026-09-21 · host: Linux 7.0.0-31-generic x86_64 (QEMU), Crystal 1.21.0
Tree `788245a` + the occupied-release change · `python3 bench/gate_arm_census.py`

The last CI gap the census notes named: the original fiber-creation
use-after-free repro (2026-08-15, three platforms) ran in no CI step, and
its own header said *"wire it up as the regression test when the defect
is fixed"*. The defect was fixed in v0.20.0 (the dying-fiber stack root),
`make dead-stack-root` gates that root deterministically, and the repro
stayed a research target.

## Measured first, at the 2026-08-17 settings

`ROUNDS=20 GCRY_POISON_FREED=1 GCRY_THREAD_CENSUS=1`, sequential:

| arm | crashes |
|---|---|
| shipped | **0 / 24** |
| `GCRY_DEAD_STACK_ROOTS=0` (the fix off; 10/24 on 2026-08-17) | **0 / 24** |
| shipped, `ROUNDS=200 GCRY_POISON_HOLDERS=1` | 0 / 12 |
| `GCRY_DEAD_STACK_ROOTS=0`, same | 0 / 12 |

The fix's own disable no longer discriminates on this host and compiler.
Then, each with `GCRY_DEAD_STACK_ROOTS=0`, 12 runs:

| added | crashes |
|---|---|
| `GCRY_STATIC_BSS_CAP=1` | 0 |
| `GCRY_TLS_ROOTS=0` | 0 |
| `GCRY_STAGED_NO_EVICT=1` | 0 |
| `GCRY_POOLED_STACK_ROOTS=0` | 0 |
| **`GCRY_DISABLE_GREG_ROOTS=1`** | **7** |
| `GCRY_DISABLE_STATIC_ROOTS=1` | 12 (exit 11 on every root gate; not this defect) |

So the word the dying stack holds is also in a suspended thread's
registers on this codegen, and the v0.19.0 register scan roots it. Two
roots cover one word; the 2026-08-17 measurement (WSL2, Crystal
1.22.0-dev) had the register scan on and still crashed 10/24 with the
dying-stack root off. `docs/ANNOUNCE.md` for v0.20.0 already carried the
other half: *0/23 under 1.21.0; every reproduction needed the 1.22.0-dev
probe compiler*. The difference is codegen — where 1.22.0-dev spilled the
word, 1.21.0 keeps it in a callee-saved register — and turning the
register scan off is what makes the stock compiler reproduce it.
The crash with both off is the same family: `SIGSEGV at 0x0`, poison in
context, the freed block 3072 bytes still FREE — the `Deque(Fiber::Stack)`
buffer — held by one live 32-byte block and four stack words.

## What changed

`bench/nested_spawn_uaf.cr` is a parent/child harness. `--child` is the
churn as before, every research knob intact. The parent forks it under
`GCRY_POISON_HOLDERS=1 GCRY_THREAD_CENSUS=1 ROUNDS=20`:

- shipped, `RUNS` (6) children: each must exit 0 and each must print
  `dead-fiber stacks: N walked` with N ≥ 1 — the window was built;
- broken, `GCRY_DEAD_STACK_ROOTS=0 GCRY_DISABLE_GREG_ROOTS=1`: tries
  until the first crash, capped at max(4·RUNS, 8); a timeout is counted
  apart and is not a crash.

Recipe runs the parent; CI step on x86_64 beside `dead-stack-root`.
Darwin and aarch64 are not wired: the broken arm's rate there is
unmeasured, and a probabilistic red arm that cannot crash on a platform
would take that job red for nothing.

## Measured, the gate

| run | shipped | broken | wall |
|---|---|---|---|
| 1 | 0 of 6 failed, 0 unwalked | crashed on try 2 | 15 s |
| 2–4 | 0 of 6 | try 1, 1, 1 | ~15 s |
| parent env `GCRY_DEAD_STACK_ROOTS=0 GCRY_DISABLE_GREG_ROOTS=1` | **4 of 6 died**, 2 unwalked | try 2 | **FAIL**, both lines |

## Census

```
harness-driven gates:              100
red direction constructed per run: 71
red direction established by hand: 29
prose claims of a hand break:      19 (nothing re-checks these)
```

**100 / 70 / 30 → 100 / 71 / 29.** `nested-spawn-uaf` moved: harness 1
(`BoundedChild`, `exit 1`, `"GCRY_…" =>`), recipe 0. No CI gap remains
in the census's leftover list; the 29 by hand are the fuzz / property /
soak / typecheck family and the research targets.
