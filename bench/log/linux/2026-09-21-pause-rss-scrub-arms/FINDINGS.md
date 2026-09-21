# Three more gates construct their red direction per run: `pause-budget`, `rss-leak`, `scrub-midswap`

**Date:** 2026-09-21 · host: Linux 7.0.0-31-generic x86_64 (QEMU), Crystal 1.21.0
Tree `788245a` + the two gates before this · `python3 bench/gate_arm_census.py`

With the census's CI-gap list empty, the 29 "by hand" were read one by
one for the cheapest honest arm. Three had one.

## `pause-budget` — the ceiling had never been seen to fire

Phase 1 requires major p99 ≤ 200 ms (the floor after GHA flakes at ~100
and ~164 ms); tip p99 here is 22 ms. `GCRY_STW_TEST_STALL_MS` already
exists for the STW watchdog — a sleep inside the stop, in the
thread-stacks phase, inside `record_pause`'s window. At 250 ms every
major measures ~267 ms and phase 1 fails. Recipe: `! GCRY_STW_TEST_STALL_MS=250
… --phases=1`, 25 majors, ~6 s. CI ran the binary directly and now runs
the recipe.

| arm | p50 | p99 | verdict |
|---|---|---|---|
| shipped, all phases | 16.2 ms | 22.0 ms | PASS |
| stall 250 ms, phase 1 | 267.2 ms | 269.6 ms | FAIL `major p99 269.64 > 200` — required |

## `rss-leak` — the harness leaks on purpose

Primary check: late-half heap median ≤ early-half + 10% (CI: 15%). No
collector knob makes a heap grow across cycles honestly, so the red
direction is the harness's own: `--leaking` roots one object in five of
each cycle in a global. One in ten was +17% against 10% — too close to
be a control; one in five is **+38%** locally and **+40%** at the CI
parameters (warm-up 20, limit 15). The arm must exit non-zero. Recipe
takes `RSS_LIMIT` / `RSS_RSS_LIMIT` so CI's parameters go through it.

## `scrub-midswap` — a detector correction, not a new arm

The harness already forks itself as `--mode=stale-off` (guard off) and
requires that child to corrupt: `overlaps > 0` and the canaries broken,
else "no positive control". It set the guard on the heap rather than
through an env knob, so the fork detector — `"GCRY_…" =>`, `--child`,
`--overshoot` — did not see a breaking arm. `--mode=` is now the same
criterion as `--child`; `scrub_midswap` is the only harness in `bench/`
that uses it, so the change credits exactly one gate.

## Census

```
harness-driven gates:              100
red direction constructed per run: 74
red direction established by hand: 26
prose claims of a hand break:      19 (nothing re-checks these)
```

**100 / 71 / 29 → 100 / 74 / 26.** `pause-budget` recipe 1, `rss-leak`
recipe 1, `scrub-midswap` harness 1.

## What the 26 are

- **Defect-finders, 11** — `fuzz`, `fuzz-replay`, `pattern-fuzz`,
  `property-test`, `layout-property-test`, `mt-property-test` and their
  `-short` twins. Their red direction *is* a collector defect; a knob
  that corrupts on purpose would test the knob. The honest check for
  these is `make mutate` (`docs/MUTATION.md`, 10/10 killed 2026-07-28),
  which the census does not read.
- **Compile-only, 2** — `darwin-typecheck`, `windows-typecheck`. Their
  red is a type error; nothing runs. Kept in the denominator on purpose
  (see the census docstring) rather than dropped to improve the number.
- **Research, not gates, 4** — `fiber-lag-cost` ("not a gate" in its own
  recipe), `darwin-page-query` (an experiment with an open question),
  `stackmap-smoke` (dormant machinery), `thread-census-symbolize` (a
  tooling check on `addr2line`).
- **Gates still owed an arm, 9** — `finalizer-complex`, `oom-test`(+short),
  `thread-storm`(+short), `trace-smoke`, `soak-smoke`, `soak`,
  `compiler-gc-contract`. (`trace-smoke` judges by `raise`, which the
  census's judge regex does not read — a first draft of this note called
  it judgement-free, and it is not. It got its arm the same day:
  `2026-09-21-trace-smoke-unsampled`.) The two soaks need an arm that
  makes the RSS ceiling fire without waiting on it.
