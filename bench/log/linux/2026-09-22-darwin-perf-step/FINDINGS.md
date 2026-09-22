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
