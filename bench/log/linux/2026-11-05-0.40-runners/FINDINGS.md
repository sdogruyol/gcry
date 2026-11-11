# 0.40 against 0.39.0 and Boehm on GitHub's runners, second refresh (2026-11-05)

`perf-ab.yml` run **41577045896**, all five runners, dispatched on
`release-0.40.0` at `2658369a`: `var` = 0.40's `src/`, `base` = `v0.39.0`,
stock Crystal 1.21.0 (Boehm), plus 16- and 64-byte pad arms of each tree
(`prepad16`, `prepad64`, `baseprepad16`, `baseprepad64`), process-fresh,
interleaved in random order per rep. crystal-metric 15 reps of the nine
benches, `stats=3`; Kemal `/json` and `/` 15 trials (`wrk -t2 -c50`, 10 s
after a 3 s warm-up) on the four Linux/macOS runners. The inputs of the first
refresh's run 41253485376 (`../2026-11-01-0.40-runners/`), with two pads a
side instead of one so the keep rule reads from the same run.

What changed in `src/` since the first refresh (`2c600dfb`), on the default
path: the growth-priced pace (`a62a47fd..f3ccc4dc`), hot heap fields first
(`19cf3a60`), the Windows inline word advance (`da2082e1`), the scrub band
(`e2737a33`), the pthread clamp (`21462240`), the parked-seed scrubs
(`23a78cd9`, `2c6a3aa4`), the Monitor scrubs (`acd6d3e4`, `7bfb0358`,
`2658369a`) and claimed-not-live (`2721f940`); the incremental and barrier
fixes are opt-in.

CPUs (the jobs' `Machine` step): `ubuntu-latest` AMD EPYC 9V74,
`windows-latest` AMD EPYC 7763, `macos-latest` Apple M1 (Virtual),
`macos-15-intel` i7-8700B. The `macos-15-intel` job ran past the workflow's
180-minute limit and was cancelled 21 s after printing its Kemal summary; its
artifact is complete (15 crystal-metric reps, 15 Kemal trials per route).
With seven arms the Intel job needs about 3 h.

Files here are the run's artifacts as downloaded: `{x86,arm64}-summary.md`
(the numbers), `-runs.json`, `-gc-counters.txt`, `-kemal-*`; `keep.txt` is
`../2026-11-01-0.40-keep-rule/keep.py` over all five runners;
`kemal-paired.txt` is `var` against `base` per trial on the four Kemal
runners, with each arm's median % of Boehm. Per-platform notes:
`bench/log/macos/2026-11-05-0.40-runners/FINDINGS.md`,
`bench/log/windows/2026-11-05-0.40-runners/FINDINGS.md`.

## Summary

- **Keep rule: 45 rows, 2 unexcused, both on Windows.** Linux (both) and
  both Macs: no row unexcused. Flagged and excused by a same-session pad
  ("placement"): arm64 JsonGenerate (timed +1.5%), Intel JsonParsePull (wall
  +2.3%) and Revcomp (+7.7%), Windows JsonGenerate, JsonParseSerializable,
  JsonParsePull, Revcomp, RegexDna. **Unexcused: Windows JsonParsePure**
  (timed +7.5% [+6.1, +8.6], wall +3.0%; 0.40's arms 0.854–0.883 s, 0.39.0's
  0.824–0.847 s) **and Windows Binarytrees** (wall +0.7% [+0.0, +3.8],
  timed +0.3% [−0.6, +1.2] within the spread; 0.40's arms 1.310–1.316 s,
  0.39.0's 1.286–1.309 s). See the Windows file. Both are code placement
  with all four 16-byte phases of each tree in one session
  (`../../windows/2026-11-06-win-phases/`). JsonParsePure: the ranges
  overlap in six of six sessions on three CPUs, and 0.40 is faster in wall
  time at the same phase. Binarytrees: the ranges meet, and the same-phase
  difference is +0.4% to +0.8%.
- **The Primes step is gone.** 0.40 collected 9 times in 73 of 75 runs
  across the five runners (one 10 on M1, one on Intel), 0.39.0 10 times in
  4 of 15 on Intel, 5 of 15 on Windows and 2 of 15 on M1. Intel Primes reads
  +1.5% wall [−1.0, +9.3] and Windows +0.6% [−4.7, +1.5], within the spread
  (first refresh: +7.6% and +6.3%). The growth-priced pace
  (`../2026-11-02-pace-growth/`).
- **arm64 JsonGenerate's fifteenth collection is gone too**: 13 collections
  in every 0.40 run, 0.39.0 14; wall −0.2% [−0.6, +0.5] (first refresh
  +1.1%). Its timed section is +1.5% [+0.9, +1.7] with `prepad64` (1.082 s)
  inside 0.39.0's 1.075–1.092 s.
- **Peaks: the JSON parse rows trade peak for less scanning.**
  JsonParseSerializable +4.4% to +14.7% and JsonParsePull +4.1% to +14.8%
  beyond the spread on all five runners but arm64 JsonParseSerializable
  (+4.9% [−1.9, +5.3]), with 14–36% less Σ scanned: the growth-priced
  pace, whose own A/B read +3% to +16% on these two rows. The largest are
  Intel's: 0.77× → 0.87× and 0.82× → 0.95× of Boehm's. **M1 JsonParsePure
  0.93× → 1.06× (+14.7% [+13.6, +15.5])**, 13 collections in every 0.40 run
  against 0.39.0's 14–16 (549–558 MiB against 473–534 MiB): every 0.40 arm
  reads 1.06× and every 0.39.0 arm 0.92–0.93×. It is not in the pace's own
  run (41293138039: 0.92× at 14 collections) nor the scrub band's
  (41336546414: 0.92×, 14); it is first in 41378856093 (`d7c6f89f`, 1.06×,
  13) and again in 41519085944 (1.06×, 13). Attributed 2026-11-06
  (`../../macos/2026-11-06-m1-peak/`): from `19cf3a60` on, crystal-metric's
  inlined `Benchmark::run` keeps the setup's dead `JsonGenerate` in a
  callee-saved register across the `GC.collect` before the timed run, a
  register pin, not the pace; 1.06× is what arm64 Linux and Windows
  read on this row for both trees. JsonGenerate keeps the high heap's
  −13.6% on both Macs; Intel Revcomp −22.8%.
- **Kemal**, `var` against `base` paired per trial, median [IQR]: `/json`
  `ubuntu-latest` −1.7% [−3.5, +0.5], arm64 +0.1% [−5.9, +3.6], M1 −1.3%
  [−4.5, +2.4], Intel −1.8% [−2.8, +4.5]; `/` −0.8% [−1.6, −0.1], −0.5%
  [−3.1, +1.9], +4.1% [−1.4, +15.8], +5.1% [−9.8, +24.6]. One row slower
  beyond the spread, `ubuntu-latest` `/`, with 0.40's arms at 99.9–100.3% of
  Boehm inside 0.39.0's 99.4–100.7%: placement. Peaks within −1.6% to +0.6%.
- **Kemal recheck on the release tip `a5a07ffe`** (Perf A/B 42834675949,
  15 trials, Kemal only), % of Boehm, 0.40 (0.39.0) [0.40's IQR]: `/json`
  `ubuntu-latest` 102.9% (104.1%) [101.0, 104.8], arm64 102.6% (104.3%)
  [99.0, 104.7], M1 106.0% (102.5%) [101.3, 115.1], Intel 112.2% (111.5%)
  [102.7, 118.2]; `/` 101.1% (100.8%), 99.9% (99.9%), 99.1% (104.8%)
  [90.7, 103.5], 108.7% (100.9%) [93.7, 113.3]. Each 0.40 median sits
  inside 0.39.0's IQR or the reverse; peaks 1.30–1.39×, as above. The docs'
  Kemal rows (measured on `2658369a`) stand.

## Linux x86_64 `ubuntu-latest` (4 vCPUs, EPYC 9V74)

crystal-metric, speed % of Boehm / peak × Boehm, 0.40 (0.39.0): Primes 111%
(111%) / 0.93×, JsonParsePure 108% (105%) / 0.80×, Binarytrees 89% (89%) /
0.74×, JsonGenerate 107% (106%) / 0.59×, JsonParseSerializable 108% (106%) /
**0.80× (0.74×)**, JsonParsePull 107% (105%) / **0.87× (0.82×)**, Revcomp 98%
(96%) / 0.55×, RegexDna 98% (96%) / 0.55×, Knuckeotide 93% (92%) / 1.41×
(1.36×). No row slower than 0.39.0 beyond the spread; JsonParsePure,
JsonGenerate, JsonParseSerializable, JsonParsePull, Revcomp, RegexDna and
Knuckeotide 1.2–2.2% faster in wall time. JsonParseSerializable and JsonParsePull peak
+8.4% [+6.8, +8.9] and +8.4% [+5.3, +8.5] at 13% and 8% fewer collections
(the pace). Knuckeotide's peak +6.9% [−0.8, +9.5] is within the spread.
Binarytrees reads 89% for both trees against 106–108% in the first refresh,
whose runner was not recorded; Boehm's 0.875 s here.

Kemal: `/json` 106.6% [105.9, 108.8] of Boehm at 1.30× (0.39.0: 110.3%,
1.31×), paired −1.7% [−3.5, +0.5]; 0.40's arms 106.6–110.7%, 0.39.0's
103.5–110.3%. `/` 100.0% [98.9, 101.1] at 1.31× (0.39.0: 100.7%), paired
−0.8% [−1.6, −0.1], placement as above.

## Linux arm64 `ubuntu-24.04-arm`

crystal-metric, 0.40 (0.39.0): Primes 103% (105%) / 0.93×, JsonParsePure 94%
(93%) / 1.07×, Binarytrees 105% (103%) / 0.74× (0.73×), JsonGenerate 101%
(101%) / 0.58×, JsonParseSerializable 103% (101%) / 0.91×, JsonParsePull
104% (101%) / **0.94× (0.90×)**, Revcomp 98% (97%) / 0.74×, RegexDna 99%
(99%) / 0.42×, Knuckeotide 93% (92%) / 1.14×. No wall time slower than
0.39.0 beyond the spread (Primes +1.2% [−1.1, +2.8]); JsonParsePure,
Binarytrees, JsonParseSerializable, JsonParsePull, Revcomp, RegexDna and
Knuckeotide 0.6–2.0% faster. JsonGenerate as in the summary. JsonParsePull's
peak +5.1% [+4.6, +10.1].

Kemal: `/json` 104.8% [103.9, 108.6] of Boehm at 1.06× (0.39.0: 107.1%,
1.06×; Boehm's peak bimodal, the IQR of both 1.06–1.33×), paired +0.1%
[−5.9, +3.6]; `/` 100.2% [96.4, 103.9] at 1.34× (0.39.0: 101.5%), paired
−0.5% [−3.1, +1.9].

## Keep rule (`keep.txt`)

`keep.py` flags a row when `var` against `base` is slower beyond its IQR in
the timed section or the wall, and excuses it ("placement") when a 0.40-code
arm's median timed section lies inside or under the 0.39.0-code arms'
range:

| runner | bench | flagged | 0.40 arms (var, p16, p64), s | 0.39.0 arms (base, bp16, bp64), s | |
|---|---|---|---|---|---|
| ubuntu-24.04-arm | JsonGenerate | time +1.5% [+0.9, +1.7] | **1.089**, **1.090**, **1.082** | 1.075, 1.075, 1.092 | placement |
| macos-15-intel | JsonParsePull | time +5.5%, wall +2.3% [+0.8, +6.4] | 2.114, 2.189, **1.994** | 2.005, 2.143, 2.151 | placement |
| macos-15-intel | Revcomp | time +14.2%, wall +7.7% [+2.6, +8.1] | **3.386**, 3.717, 3.914 | 3.298, 3.512, 3.603 | placement |
| windows-latest | JsonParsePure | time +7.5% [+6.1, +8.6], wall +3.0% | 0.883, 0.857, 0.854 | 0.824, 0.841, 0.847 | **unexcused** here; placement with four phases a side (`../../windows/2026-11-06-win-phases/`) |
| windows-latest | Binarytrees | wall +0.7% [+0.0, +3.8] | 1.316, 1.310, 1.312 | 1.309, 1.286, 1.306 | **unexcused** here; placement with four phases a side (the same) |
| windows-latest | JsonGenerate | time +1.3% [+0.9, +1.6] | 1.359, **1.302**, **1.310** | 1.341, 1.295, 1.299 | placement |
| windows-latest | JsonParseSerializable | time +6.4%, wall +3.1% | 0.735, **0.719**, **0.696** | 0.691, 0.684, 0.727 | placement |
| windows-latest | JsonParsePull | time +6.4%, wall +2.8% | 0.729, **0.711**, **0.688** | 0.686, 0.677, 0.714 | placement |
| windows-latest | Revcomp | time +15.7%, wall +6.1% | 1.461, **1.388**, **1.275** | 1.263, 1.264, 1.390 | placement |
| windows-latest | RegexDna | time +0.8%, wall +1.3% | **3.465**, **3.446**, **3.400** | 3.440, 3.464, 3.516 | placement |

Bold: inside or under the 0.39.0-code range. Every other row reads `ok`
(35 of 45). `keep.py` also prints a peak beyond the spread on its own; those
are the summary's peaks.
