# The perf gate could not be earned by sampling: the rule was the blocker

Date: 2026-09-13/14 (overnight) · runner class: `ubuntu-latest` · layout:
headerless · tool: `bench/perf_gate_margin.py`

`PERF_GATE_BASELINE=1` has been the next step on the benchmark-alerts item for a
year, always behind the same sentence: *record more green runs, then turn it on*.
Tonight's first measurement says that plan could never have finished.

## The rule, in the unit the question is asked in

`perf_compare.py --record` derived the tolerance as
`max(half the observed range, 1.5 x IQR, floor)`. Both of the first two terms are
**proportional to the spread**, so the gate sits a fixed number of standard
deviations from the mean however many runs go into it. Simulated over normal
samples, 400 draws per n:

| runs | tolerance in sd | false red per metric per run |
|---|---|---|
| 10 | 2.32 | 1.01% |
| 23 | 2.28 | 1.14% |
| 40 | 2.29 | 1.10% |
| 100 | 2.51 | 0.60% |
| 500 | 3.04 | 0.12% |
| 1000 | 3.24 | 0.06% |

The 23-run baseline this repo shipped read 2.12-2.62 sd across its three gated
metrics — 2.7% combined, one false red every 37 runs. Reaching the 3.3 sd the
item asks for would have taken about **1200 green master runs**, against a
30-day artifact retention. "More samples" was not a lever; it was a treadmill.

## Stating the tolerance in standard deviations

`TARGET_SD = 3.3`, floored per metric as before. Recorded on 24 green headerless
runs:

| metric | median | tolerance | gate fires | sd | sd out | P/run | fixed floor |
|---|---|---|---|---|---|---|---|
| `pct_json` | 100.45 | ±14.39 | below **86.06** | 4.36 | 3.37 | 0.04% | 65 |
| `rss_x` | 0.9465 | ±0.2495 | above **1.196** | 0.0756 | 3.57 | 0.02% | 1.25 |
| `pause_p50_ms` | 0.6404 | ±0.3407 | above **0.981** | 0.1033 | 3.34 | 0.04% | 2.5 |
| `pct_root` | 99.45 | ±15.58 | warn-only | 4.72 | 3.14 | — | — |

**0.10% combined per run — one false red per ~1000 runs**, against the 0.145%
the criterion asks for. Leave-one-out (record from 23, gate the 24th, each in
turn) passes **24 of 24**, and the three newest runs pass the committed baseline
directly.

And the gate is now *tighter than the fixed floors on all three metrics*:
86.06% against a 65% floor, 1.196x against 1.25x, 0.98 ms against 2.5 ms. Under
the old rule `pct_json` cleared its floor by 24.8 pp and `rss_x` did not clear
its own recording session — one of the ten runs sat outside its own tolerance.

So `PERF_GATE_BASELINE=1` is on in the perf-smoke job.

## What it cannot do, stated plainly

3.3 sd on this runner class is about **14 pp of `/json` throughput**, 0.25x of
post-GC RSS and 0.34 ms of pause. A regression smaller than that is invisible to
a single run, and no narrower band fixes it — narrowing trades the false-red rate
back. Sensitivity at a fixed false-alarm rate needs *confirmation across runs*:
two consecutive runs outside 2 sd is 0.05% per pair with a 2-sd band, which
would catch a 9 pp regression at the same false-red rate as today's 14 pp gate.
That needs state CI does not keep between runs, which is the next piece of work
on this item rather than a reason to wait before gating.

## The tool

`bench/perf_gate_margin.py` collects every green master run's artifact on the
current layout, records a candidate baseline through `perf_compare.py` so the
rule has one home, and prints the margin in sd with the false-alarm arithmetic
and its verdict. It is how this was measured and how the next flip decision
should be made rather than argued.

## Sensitivity: confirmation across runs (2026-09-13, later)

The gap this leaves is a regression between about 5 and 14 pp: inside the
single-run gate, invisible. Narrowing the band trades the false-alarm rate
straight back, so the answer is a second observation rather than a tighter one.

Two runs in a row on the wrong side of **2 sd** is 0.05% per pair under
normality — *lower* than the single-run gate's own rate — and catches ~9 pp.
Checked against the 24 recording runs, deviations signed so negative is worse:

| threshold | single excursions (of 72 metric-runs) | consecutive same-metric pairs |
|---|---|---|
| 1.5 sd | 2 | **0** |
| 2.0 sd | 1 | **0** |
| 2.5 sd | 1 | **0** |

So the rule would have fired zero times across two days that include the hours a
shared runner pool is slow — which is the case it could otherwise mistake for a
regression.

Implemented as `perf_compare.py --prev PREV_SUMMARY`, fed by
`bench/fetch_prev_perf_summary.sh`: CI keeps no state between runs, but it keeps
artifacts, and `perf-smoke-report` is uploaded by the very job that needs it.
Every failure path there degrades to "no previous run" — a missing or expired
artifact, a rate limit, a layout change — because a perf job that goes red
because it could not download a file is worse than one that judges a single run.
Every comparison row now also prints its deviation in sd, which is the number
the rule acts on.

## And the artifact was 200 MB of the repository

Downloading two dozen `perf-smoke-report` artifacts to record a baseline filled
a 16 GB `/tmp`. The upload was `path: bench/log/`, i.e. the whole checked-in log
tree — already in the repository, ~200 MB a copy — while every consumer reads
exactly one `summary.json` out of it. `perf_smoke.sh` now publishes the run's own
JSON to `bench/log/_run/` and that is what CI uploads: a few KB. The three
readers accept all three shapes, since 30 days of the old artifacts stay
downloadable.

