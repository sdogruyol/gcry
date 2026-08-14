# The positive control, re-established on the current probe compiler

**Status: the corruption still reproduces at `75a9d25` without the fix — 7 of 10
trials. The fixed tree measured 0 of 10 the same morning, same host, same
compiler (`../2026-08-14-tip-fixed-tipnoec/`).**

Apple M2 Pro, Darwin 25.5.0 / macOS 26.5.1 arm64, gcry built by Crystal 1.21.0,
acikturkiye built by probe compiler **1.22.0-dev `656fc4620`** (2026-08-11).
`acik_stackmap_ab.sh`, `tipnoec`, `wrk -c 100 -d 30`, dual `/gc-collect`.

## Why this was run

The A/B that validated `2936248` ran under probe compiler `4a965f423`. That
compiler has since moved to `656fc4620`, and this defect is **codegen
dependent** — whether a pointer lives in a register or gets spilled is a codegen
choice, which is why Linux never saw it and why Boehm on the identical compiler
was 0/3. A base rate measured under one compiler says nothing about another. So
before quoting the fix as re-confirmed, the plain arm had to be measured again.

| trial | req/s | RSS KiB | Non-2xx |
|------:|------:|--------:|--------:|
| 1 | 910.10 | 36,096 | 0 |
| 2 | 902.79 | 38,288 | 0 |
| 3 | 895.13 | — | **1** |
| 4 | 885.94 | — | **1** |
| 5 | 881.04 | — | **1** |
| 6 | 887.57 | — | **1** |
| 7 | 891.53 | — | **1** |
| 8 | 901.25 | 34,688 | 0 |
| 9 | 895.65 | — | **1** |
| 10 | 877.04 | — | **1** |

**7/10.** In range with the 8/10 and 4/10 this arm produced on 2026-08-11 under
the older probe compiler, and against the fixed tree's 0/10: binomial against a
0.7 base rate, p ≈ 6e-6; Fisher exact on the 2×2, p ≈ 0.003.

## The first attempt measured nothing, and why

The first run of this control put the harness in a `git worktree` at `75a9d25`
and returned 0/10 — which was read, briefly, as "the base rate drifted to zero
on the new compiler". It had not.

`acikturkiye/lib/gcry` is a **symlink to the main gcry checkout**. Running the
harness from a worktree changes which *script* runs; it does not change which
gcry the application compiles against. So that run built the app against the
**fixed** tree and 0/10 was the fix working, correctly, under a label that said
the opposite.

The symlink is what selects the arm. This run repoints it and verifies the tree
under test has no `stw_greg_ok` marker before starting. The earlier run is kept
as `../2026-08-14-tip-fixed-tipnoec/`, relabelled for what it actually
measured — it is the fixed arm of this pair, not a discarded run.

That failure mode is the one this log already warns about twice: a green
reachable without observing anything. It is easy to hit from a new direction
each time.

## What this does and does not establish

**Does:** the workload still produces the defect on the current toolchain at a
high rate, so a clean fixed arm on this compiler is worth something rather than
being a rate artefact. That was the whole question.

**Does not:** these two arms differ by a commit range as well as by the fix —
`75a9d25` plain against tip with the fix. The clean single-commit contrast is
still the 2026-08-11 session's `75a9d25` plain **4/10** against `75a9d25` + the
fix **0/10**, which is the number to quote for attribution. This pair
re-establishes the control; it does not replace that A/B.

**Still open**, unchanged by this run: whether Linux has an analogous gap on any
path (the `greg-roots` gate now runs there, which is what will answer it), and
any link to the 2026-08-08 production SIGSEGV, which remains an unproven bet.
