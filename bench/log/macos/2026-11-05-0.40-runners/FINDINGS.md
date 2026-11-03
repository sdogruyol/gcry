# 0.40 against 0.39.0 and Boehm on GitHub's macOS runners, second refresh (2026-11-05)

Same dispatch and method as `bench/log/linux/2026-11-05-0.40-runners/FINDINGS.md`
(run 41577045896, `var` = 0.40 at `2658369a`, `base` = `v0.39.0`, Boehm =
stock Crystal 1.21.0, 16- and 64-byte pad arms of each tree), which holds the
cross-runner summary and the keep-rule table. Memory is `ru_maxrss`. Raw:
`arm64-*` (`macos-latest`, Apple M1 (Virtual), 3 vCPUs), `intel-*`
(`macos-15-intel`, i7-8700B); `*-summary.md` are the numbers. One run each.
The Intel job was cancelled at the workflow's 180-minute limit 21 s after
printing its Kemal summary; its artifact holds all 15 reps and 15 trials.

## macOS arm64 `macos-latest`

| bench | Boehm | 0.39.0 speed / peak | 0.40 speed / peak | 0.40 vs 0.39.0 wall | peak |
|---|---:|---|---|---:|---:|
| Primes | 1.109 s, 696 MiB | 106% / 0.89× | 108% [107, 113] / 0.89× | −1.8% [−9.1, +2.1] | +0.0% |
| JsonParsePure | 1.287 s, 518 MiB | 98% / 0.93× | 99% [94, 106] / **1.06×** | +1.5% [−3.6, +6.5] | **+14.7% [+13.6, +15.5]** |
| Binarytrees | 0.829 s, 39 MiB | 94% / 0.94× | 98% [97, 102] / 0.94× | −3.4% [−8.7, −1.1] | +0.1% |
| JsonGenerate | 2.451 s, 1198 MiB | 103% / 0.74× | 106% [100, 112] / **0.64×** | +0.3% [−6.2, +2.3] | −13.6% [−13.7, −13.6] |
| JsonParseSerializable | 1.424 s, 498 MiB | 104% / 0.87× | 105% [101, 108] / 0.94× | −3.1% [−6.7, −1.1] | +6.5% [+5.0, +9.1] |
| JsonParsePull | 1.426 s, 521 MiB | 106% / 0.85× | 103% [101, 109] / 0.92× | +1.2% [−1.4, +6.5] | +9.4% [+6.1, +11.9] |
| Revcomp | 3.207 s, 830 MiB | 98% / 0.61× | 98% [96, 101] / 0.61× | −0.5% [−4.3, +1.0] | −0.0% |
| RegexDna | 3.612 s, 536 MiB | 98% / 0.43× | 99% [94, 101] / 0.43× | −1.5% [−4.4, +5.3] | −0.0% |
| Knuckeotide | 1.083 s, 47 MiB | 90% / 1.32× | 89% [82, 99] / 1.32× | −2.1% [−9.4, +4.6] | +0.0% |

No wall time or timed section slower than 0.39.0 beyond its spread
(`keep.txt`: every M1 row `ok`); Binarytrees −3.4% and JsonParseSerializable
−3.1% faster. 89–108% of Boehm's speed on all nine rows (0.39.0 90–106%).
Σ mark is lower on Knuckeotide (−15.4%) and JsonParsePure (−10.3%).

Peaks:

- **JsonParsePure 0.93× → 1.06× of Boehm's (+14.7%).** 0.40 collects 13
  times in every run (549–558 MiB), 0.39.0 14–16 times (473–534 MiB); every
  0.40 arm reads 1.06× and every 0.39.0 arm 0.92–0.93×, so it is not
  placement. The step is in the tip's history between `421b09be` (scrub
  band run 41336546414: 0.92×, 14 collections) and `d7c6f89f` (41378856093:
  1.06×, 13); the growth-priced pace's own run (41293138039) read 0.92× at
  14. Not attributed [INFERENCE: one collection fewer under the pace once a
  change in that range made the cycle cheaper]. 1.06–1.07× is where this row
  sits for both releases on arm64 Linux and Windows.
- JsonParseSerializable +6.5% and JsonParsePull +9.4% (0.94× and 0.92×):
  the pace's trade (`../../linux/2026-11-02-pace-growth/`), 20–25% less
  Σ scanned.
- JsonGenerate −13.6%, the high heap (`../2026-10-31-heap-high/`), as in the
  first refresh.

Kemal, 15 trials (`arm64-kemal-summary.md`; paired `var`/`base` per trial in
`../../linux/2026-11-05-0.40-runners/kemal-paired.txt`):

- `/json`: 101.4% [94.9, 107.2] of Boehm at 1.37× (20.2 against 14.9 MiB);
  0.39.0 102.0%, 1.40×; paired −1.3% [−4.5, +2.4], peak −0.9%.
- `/`: 100.8% [94.4, 112.2] at 1.33×; 0.39.0 93.0%, 1.36×; paired +4.1%
  [−1.4, +15.8], peak −1.1%. The `/` trials are bimodal for every arm, as in
  the earlier runs.
- Work per 1 000 requests on `/json`: the same 0.710 collections for both
  trees and 28% less pause (0.245 against 0.341 ms), as the first refresh
  read (26–30%). Not attributed.

## macOS x86_64 `macos-15-intel`

crystal-metric, speed % of Boehm / peak × Boehm, 0.40 (0.39.0): Primes 100%
(104%) / 0.92× (0.93×), JsonParsePure 102% (98%) / 0.80× (0.81×),
Binarytrees 133% (140%) / 0.96×, JsonGenerate 99% (99%) / 0.64× (0.75×),
JsonParseSerializable 101% (101%) / **0.87× (0.77×)**, JsonParsePull 97%
(101%) / **0.95× (0.82×)**, Revcomp 94% (97%) / 0.53× (0.71×), RegexDna 102%
(104%) / 0.42× (0.44×), Knuckeotide 99% (101%) / 1.56×. This runner's spread
is wide (Primes' IQR 92–106% of Boehm).

- **JsonParsePull +2.3% wall [+0.8, +6.4], Revcomp +7.7% [+2.6, +8.1]:
  placement by the keep rule** (`prepad64` 1.994 s under 0.39.0's 2.005 s on
  JsonParsePull; 0.40 unpadded 3.386 s inside 0.39.0's 3.298–3.603 s on
  Revcomp, whose arms span 19%).
- Primes +1.5% [−1.0, +9.3] and Binarytrees +1.9% [−1.4, +6.6] are within
  the spread. Primes collected 9 times in 14 of 15 0.40 runs, 0.39.0 10
  times in 4 of 15 (padded by 16: 13 of 15). The first refresh's +7.6% was
  that step.
- JsonParsePure −2.5% [−6.0, −0.4] and Knuckeotide −2.4% faster.
- Peaks: JsonParseSerializable +14.7% [+12.3, +16.7] and JsonParsePull
  +14.8% [+12.4, +17.8] (0.87× and 0.95× of Boehm's), the pace's trade, with
  32% and 14% less Σ scanned; JsonGenerate −13.8% and Revcomp −22.8%, the
  high heap.

Kemal: `/json` 106.1% [92.6, 115.2] of Boehm at 1.36× (0.39.0: 107.5%,
1.39×), paired −1.8% [−2.8, +4.5]; `/` 103.4% [89.4, 126.7] at 1.38× (0.39.0:
101.6%, 1.40×), paired +5.1% [−9.8, +24.6]; peaks −1.6% and −0.8%. Pause per
1 000 requests 11–14% less (0.923 against 1.032 ms, 0.202 against 0.235 ms).
