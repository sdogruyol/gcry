# The perf baseline, re-recorded on the layout that ships

Date: 2026-09-13 · runner: `ubuntu-latest` (GitHub-hosted, 2 vCPU) · layout:
headerless · tree: `9f99142`

`bench/baseline/perf_smoke.json` was recorded on 2026-09-09 from the header
layout, hours before #41 made headerless the compile default. Since 0.26.0 it
has described a build nobody makes: `perf_compare.py` printed `STALE:` and
refused to gate on every run, which is the control working, and the follow-up
it named — re-record from green runs on this layout — is this.

## What was recorded

Every green master run since the flip, taken from the `perf-smoke-report`
artifacts the job already uploads, so no quiet host was needed. The plan said
the first ten; ten was wrong, and the held-out runs are why.

| run | commit | `pct_json` | `rss_x` | `pause_p50_ms` | `pct_root` |
|---|---|---|---|---|---|
| `34489891717` | `e5bae04` | 99.7 | 0.989 | 0.4039 | 98.9 |
| `34492754300` | `93ce985` | 98.8 | 0.917 | 0.5281 | 98.0 |
| `34515857869` | `9d82c2c` | 100.4 | 0.974 | 0.5661 | 96.4 |
| `34676356015` | `95a8b2e` | 96.6 | 0.93 | 0.7503 | 99.5 |
| `34679010652` | `1e90246` | 101.9 | 0.978 | 0.6872 | 104.4 |
| `34689205144` | `9c4fb81` | 104.1 | 0.993 | 0.6864 | 100.1 |
| `34694138709` | `fedb7b4` | 101.5 | 0.867 | 0.7434 | 97.5 |
| `34696514027` | `7cc622a` | 105.2 | 0.921 | 0.5915 | 101.2 |
| `34700590800` | `c5bb5e3` | 97.8 | 0.976 | 0.6498 | 91.1 |
| `34704879814` | `c84b438` | 103.8 | 0.949 | 0.6616 | 98.0 |
| `34708222687` | `3ddc8bc` | 106.5 | 0.977 | 0.6399 | 91.2 |
| `34709132070` | `0f95cdd` | 95.7 | 0.888 | 0.5925 | 92.1 |
| `34711839727` | `9cde76a` | 97.6 | 0.984 | 0.7431 | 101.8 |
| `34712695240` | `ab7d265` | 105.3 | 0.919 | 0.399 | 105.5 |
| `34713568693` | `4394f08` | 97.7 | 0.944 | 0.4824 | 111.0 |
| `34714425709` | `f3d2457` | 97.5 | 0.77 | 0.6059 | 101.7 |
| `34715279012` | `d76a248` | 108.4 | 0.991 | 0.5984 | 100.3 |
| `34716820153` | `ce0f2a8` | 99.7 | 0.941 | 0.7251 | 94.0 |
| `34738645679` | `da01ae7` | 100.8 | 0.989 | 0.7386 | 100.9 |
| `34742950000` | `72bea50` | 94.7 | 0.946 | 0.603 | 102.1 |
| `34747732363` | `5e9f229` | 95.0 | 0.912 | 0.6322 | 92.8 |
| `34750281491` | `8cf3640` | 107.1 | 0.947 | 0.6784 | 102.7 |
| `34759782384` | `9f99142` | 93.9 | 0.952 | 0.6695 | 95.4 |

The first ten read the `pct_json` spread as **96.6-105.2**. The thirteen after
them ranged **93.9-108.4**. A baseline recorded on the ten would have put the
gate at 92.96, i.e. **0.94 pp** from a false alarm on a run that had already
happened — so the recording takes all 23, and the tolerance widens from ±7.99
to ±9.9 because the spread it is derived from is the real one.

| metric | baseline | tolerance | gate fires | fixed floor | self-fires |
|---|---|---|---|---|---|
| `pct_json` | 99.7 | ±9.9 | below **89.8** | 65 | 0 of 23 (min 93.9) |
| `rss_x` | 0.947 | ±0.1115 | above **1.058** | 1.25 | 0 of 23 (max 0.993) |
| `pause_p50_ms` | 0.6399 | ±0.2 | above **0.8399** | 2.5 | 0 of 23 (max 0.7503) |
| `pct_root` | 99.5 | ±9.95 | warn-only | — | — |

Leave-one-out — record from 22, gate the 23rd, for each — passes **23 of 23**.
The previous recording's `rss_x` self-fired 1 of 10; on this layout post-GC RSS
is both lower and tighter (0.77-0.993 against 0.98-1.13), which is the headerless
RSS win showing up in the noise as well as the median.

## And gating still stays off, now for a reason with a number

The open question on this item was `PERF_GATE_BASELINE=1`. Zero self-fires is
not the same as a gate worth blocking a PR on, so what matters is the distance
from the mean to the gate in units of the runner's own spread:

| metric | mean | sd | gate | z | P(fire)/run | 1 false red per |
|---|---|---|---|---|---|---|
| `pct_json` | 100.4 | 4.24 | 89.8 | 2.50 | 0.62% | 162 runs |
| `rss_x` | 0.9415 | 0.0508 | 1.058 | 2.30 | 1.07% | 94 runs |
| `pause_p50_ms` | 0.6251 | 0.0996 | 0.8399 | 2.16 | 1.55% | 65 runs |

Any of the three fires the run, so the combined rate is **3.2% per run — one
false red every ~31 runs**, on a branch that takes several pushes a day. That
is a gate nobody would trust for a week, and the tolerance cannot simply be
widened: at ±9.9 the `pct_json` gate already sits 24.8 pp *above* the 65% fixed
floor it was meant to tighten, so widening it hands the job back to the floor.

What would earn the flip: a tolerance at ~3.3 sd per metric (combined ~0.15% per
run, one red per ~650) — which is what more samples buy, since the tolerance is
`max(half-range, 1.5x IQR, floor)` and both of the first two shrink toward the
true spread as n grows. The artifacts accumulate on their own; this is a
re-record in a few weeks, not work.

## A report that contradicted itself

Recording the first non-stale baseline this repo has had exposed a latent
defect in the comparator's own output: `baseline: none recorded yet` was the
`else` of the staleness chain, so it printed under **every** comparison that
was not stale — and every baseline that had ever shipped here was stale (no
`layout` field, then the wrong one), so the line had never been reachable by a
green path. The first fresh baseline printed its own provenance and then denied
it existed, in the same report.

Fixed, and covered: the "none recorded yet" line now belongs to the branch that
has no provenance, and `make perf-baseline` gained the fixture for the converse
— a fresh, matching baseline must not deny itself. The fixture is red against
the pre-fix report and green after.
