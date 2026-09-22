# The Darwin perf step, and the three ways it would have gone wrong

**Date:** 2026-09-22 · host: Linux 7.0.0-31-generic x86_64 (QEMU), Crystal 1.21.0
Tree `60d8025`

The CI-asymmetry item's last missing piece is a perf gate on Darwin. The
machinery is all there — `perf_smoke.sh` already reads RSS with `ps -o
rss=` off Linux, writes under `bench/log/macos/`, and labels the runner —
so what was missing is `wrk`, a step, and a baseline. Writing it found
three things that would have made the first Darwin run lie or die.

## 1. A cross-runner baseline gated

`perf_compare.py` printed `NOTE: this run is on X, the baseline was
recorded on Y — absolute numbers do not carry across runner classes` and
then **compared and gated anyway**. The ratios are same-host, but a
tolerance is a statement about *spread*, and a macOS runner's spread is
not `ubuntu-latest`'s. This is the same mistake the file already refuses
for a layout flip, where it cost two silent baselines (0.24.0, 0.26.0).
Now `STALE: … Reporting only`, with a fixture in the selftest and the
converse fixture beside it so the rule cannot disable the gate wholesale.

## 2. A missing baseline file raised

`json.load(open(path))` on a path that does not exist is a traceback, and
the first Darwin run would have had exactly that: the platform gets its
step before it has the green runs to record from. A missing file is an
*unrecorded* baseline — it reports what it measured, names the path it
looked for, and exits 0 even in gate mode, because there is nothing to
gate against. Fixture added.

## 3. One baseline path for two platforms

`perf_smoke.sh` hardcoded `bench/baseline/perf_smoke.json`. It picks by
platform now (`perf_smoke_macos.json` on Darwin), `PERF_BASELINE` still
overrides, so the Darwin step looks for its own file and finds nothing
yet — which is the honest state.

## The step

A separate `perf smoke (darwin)` job rather than a step inside `test
(darwin native)`: that job runs 376–538 s against a 20-minute bound (one
outlier at 1219 s), and two `crystal build --release` of Kemal would put
it at the edge. Report-only, the script's loose default floors, and the
summary uploaded — which is what a recording will be made from once
enough green runs exist. No Darwin number is invented here; the Darwin
soak ceiling was measured rather than assumed for the same reason.

Verified locally: selftest green with the three new fixtures; breaking
the cross-runner rule reddens it (`SELFTEST FAIL: cross-runner baseline
gated (exit 1)`); a missing baseline path with `--gate` exits 0 and says
so; `make perf-baseline` green.

## The first Darwin run, and what it measured about the instrument

`perf smoke (darwin)` ran (run `35721407250`) and failed its thr floor:

```
/      gcry = 92.6% of Boehm  (informational)
/json  gcry = 65.6% of Boehm  (gate >= 70%)
RSS x = 1.153 (<= 1.5)   pause_p50 = 0.45 ms (<= 3.0)
```

The 65.6% is not a number about the collector. Its inputs:

```
median=75804.96 runs=[54839.73, 75804.96, 109267.95] noise=0.0
median=46896.15 runs=[42548.59, 46896.15, 78698.68] noise=0.0
```

At `BENCH_RUNS=3` the script discards min and max and **one sample
survives**, so the "median" is a single draw from a distribution with a
2x spread — and `noise_ratio`, the IQR of one value over itself, printed
**0.0**: the best possible reading on the noisiest data this script has
taken. The instrumented pass in the same job, seconds later, had gcry
*ahead* of Boehm (73462 against 70167 req/s).

Three consequences, all applied:

- `noise_ratio` is `null` when fewer than three samples survive the
  discard, and the line says `noise=blind, only N sample survived the
  discard (full spread 1.72x)`. A blind instrument says so instead of
  reading zero — the same rule this repo applies to its gates.
- The Darwin job takes `BENCH_RUNS=7`, which keeps five.
- It passes **no floors** (`MIN_PCT=0`, ceilings out of reach). The
  defaults are Linux numbers; applying them to an unmeasured host is how
  a first run produces a red that means nothing. The recorded baseline
  becomes the gate when it exists, and the artifact carries the numbers
  meanwhile.

## And the number the instrument was hiding

Same host, same commit, same collector — only `BENCH_RUNS` changed:

| samples | kept | `/json` % of Boehm | noise |
|---|---|---|---|
| 3 | 1 | **65.6** | reported 0.0, actually blind |
| 7 | 5 | **111.6** | 0.05 – 0.23 |

A 46-point swing out of the sampling alone, and the direction that
matters: Darwin CI is **not** below Boehm on `/json`, it is ahead. Had
the first run's floor been "fixed" to 65% instead of the instrument, the
repo would have carried a Darwin thr number that was noise, and a gate
that could never fire.

Per-run spread on this runner is 5–23% against the Linux baseline's
4.1% *across* runs, so a Darwin recording will need either more samples
per run or a wider tolerance, and which one is a measurement rather than
a preference.

## What this says about the Linux job, and what was deliberately not done

`perf smoke (kemal /json vs Boehm)` runs `BENCH_RUNS=3` as well, so every
`noise=0.0` it has ever printed was the same blind reading, and every
per-run `pct_json` it recorded is a one-sample median. The 48-run
baseline is **not** invalidated by that — its tolerance comes from the
spread *across* runs, which contains this noise rather than ignoring it —
but the gate is wider than it needs to be because of it: less per-run
noise would mean a smaller sd and a gate that fires below today's ~14 pp.

Raising it is therefore a real improvement and a real cost: the recorded
distribution is the n=3 one, so the change requires re-recording from
~20+ green runs at the new sampling, and adds ~2 min to a job that runs
on every push. Left at 3 deliberately, with the number written down, so
the next person weighing it has both halves instead of discovering the
first one again.

## The recording tool the baseline never had

The 48-run Linux baseline was assembled by downloading runs one at a
time. A hand job is one nobody repeats, which is how a baseline survives
two default flips unnoticed (0.24.0, 0.26.0) — and the Darwin step now
needs exactly that job done again.

`bench/collect_perf_summaries.sh` does it, parameterised rather than
copied: `ARTIFACT` and `RUNNER` select the job and whose numbers inside
it, summaries on another runner or layout are skipped and counted, and
it says so when it has fewer than the twenty a recording should use.
`bench/fetch_prev_perf_summary.sh` takes the same two variables, so the
day Darwin gates it does not need a second copy of that script either.

Run against CI today:

| target | collected |
|---|---|
| `perf-smoke-report` / `ubuntu-latest` (last 8 runs) | 5 |
| `perf-smoke-report-macos` / `macos-latest` (last 12) | 2 |

The two Darwin samples, both at `BENCH_RUNS=7`: `pct_json` **111.6** and
**111.5**, `rss_x` 1.092 and 1.176. Consistent on the metric that swung
46 points under the old sampling.

## The first four samples say the protocol cannot gate yet

| run | `pct_json` | `rss_x` | `pause_p50_ms` |
|---|---|---|---|
| 1 | 111.6 | 1.092 | 0.485 |
| 2 | 111.5 | 1.176 | 0.529 |
| 3 | **148.1** | 1.121 | 0.463 |
| 4 | 103.9 | 1.291 | 0.476 |

Cross-run sd: `pct_json` **19.9 pp**, `rss_x` 0.088, `pause_p50_ms`
0.029. The Linux baseline's are 4.12, 0.059 and 0.098 — so Darwin's
throughput spread is **4.8x** Linux's, and a 3.3 sd gate built on it
would fire 65.6 pp below the mean. That is looser than the 70% fixed
floor it would replace, which makes it not a gate at all. `rss_x` and
`pause_p50_ms` are in Linux's range already.

So the sampling goes up now rather than after twenty samples are spent
under a protocol that cannot produce a usable tolerance:
`WRK_DURATION=10` on the Darwin job (Linux keeps 5). Whether it helps is
the measurement; the number to beat is the 4.1 pp Linux manages, and the
four samples above are not comparable with what follows — a different
protocol is a different distribution, the same rule that makes a
cross-runner baseline report-only.

What is already worth stating: on `/json` this collector is **ahead of
Boehm on the macOS runner**, by 4 to 48 points depending on the hour.
The open question is the runner's variance, not the collector's
throughput.

## First sample at `WRK_DURATION=10`

`pct_json` **96.1** (`/` 139.7), `rss_x` 1.146. Per-run noise 0.09 and
0.24 — no better than at 5 s, so the within-run spread is not duration
starvation. Whether the *cross-run* spread narrows is what the next
samples answer; the four at 5 s were 111.6 / 111.5 / 148.1 / 103.9 and
do not mix with these.
