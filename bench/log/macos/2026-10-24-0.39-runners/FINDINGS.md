# 0.39 against 0.38.0 and Boehm on GitHub's macOS runners (2026-10-24)

Same dispatch and method as `bench/log/linux/2026-10-24-0.39-runners/FINDINGS.md`
(run 39944941478, `var` = 0.39 at `b888ac96`, `base` = `v0.38.0`, Boehm =
stock Crystal 1.21.0, 16-byte pad arms), which holds the cross-runner
summary. Memory is `ru_maxrss`. Raw: `arm64-*` (`macos-latest`, Apple M1, 3
vCPUs), `intel-*` (`macos-15-intel`, i7-8700B); `*-summary.md` are the
numbers. One run each.

No crystal-metric wall time is slower than 0.38.0 beyond its spread on either
runner. Every row but Knuckeotide is within 1.1× Boehm's peak on both.

## macOS arm64 `macos-latest`

| bench | Boehm | 0.38.0 speed / peak | 0.39 speed / peak | 0.39 vs 0.38.0 wall | peak |
|---|---:|---|---|---:|---:|
| Primes | 1.179 s, 696 MiB | 107% / 0.89× | 95% [85, 113] / 0.88× | +6.2% [−0.9, +17.6] | −1.0% |
| JsonParsePure | 1.299 s, 517 MiB | 95% / 0.94× | 92% [87, 101] / 0.93× | −1.7% [−3.5, +6.0] | −1.1% |
| Binarytrees | 0.901 s, 39 MiB | 91% / 0.94× | 100% [94, 103] / 0.94× | −5.4% [−12.1, −0.3] | +0.0% |
| JsonGenerate | 2.518 s, 1198 MiB | 99% / 0.77× | 101% [97, 111] / 0.74× | −3.1% [−13.5, +3.0] | −3.9% |
| JsonParseSerializable | 1.490 s, 498 MiB | 103% / 0.91× | 105% [94, 110] / 0.88× | +2.4% [−2.2, +10.2] | −1.8% |
| JsonParsePull | 1.393 s, 518 MiB | 106% / 0.87× | 102% [99, 107] / 0.86× | −0.4% [−7.5, +7.3] | −1.4% |
| Revcomp | 3.288 s, 834 MiB | 99% / 0.61× | 97% [92, 105] / 0.63× | −0.5% [−4.1, +1.3] | +3.6% [−0.0, +3.6] |
| RegexDna | 3.907 s, 536 MiB | 100% / 0.43× | 102% [99, 105] / 0.43× | −4.6% [−8.0, +0.9] | +0.0% |
| Knuckeotide | 1.145 s, 46 MiB | 92% / 1.59× | 90% [85, 98] / 1.33× | +2.1% [−4.4, +5.0] | −16.4% [−16.5, −16.3] |

This run's spread is wide (Primes' IQR spans 85–113% of Boehm). JsonParsePure
reads lower for both trees than in 0.38.0's own run (0.38.0: 95% here, 102% there).

Kemal, 15 trials (`arm64-kemal-summary.md`; paired `var`/`base` per trial
computed from `arm64-kemal-runs.json`):

- `/json`: 107.9% [100.2, 121.3] of Boehm at 1.41× (20.4 against 14.4 MiB);
  0.38.0 102.4%, 1.40×; paired +2.0% [−3.2, +13.5], peak −0.2%.
- `/`: 82.1% [77.5, 100.7] at 1.35×; 0.38.0 96.0%, 1.36×; paired −7.0%
  [−25.6, −0.5], slower beyond the spread. The trials are bimodal for every
  arm (Boehm 56–116k req/s): 0.39 reached the upper mode (> 90k) in 1 of 15
  trials, 0.38.0 in 7, 0.39 padded by 16 bytes in 8, CPU per 1 000 requests
  11.10 ms against 10.21 (Boehm 9.73). Not attributed; `/` on this runner was
  100.0% in 0.38.0's run.

## macOS x86_64 `macos-15-intel`

crystal-metric, speed % of Boehm / peak × Boehm, 0.39 (0.38.0): Primes 99%
(100%) / 0.93×, JsonParsePure 101% (100%) / 0.80×, Binarytrees 157% (150%) /
0.96×, JsonGenerate 102% (105%) / 0.65×, JsonParseSerializable 107% (100%) /
0.78× (0.85×), JsonParsePull 104% (99%) / 0.82× (0.91×), Revcomp 102% (99%)
/ 0.69× (0.67×), RegexDna 102% (102%) / 0.49×, Knuckeotide 100% (99%) /
1.56× (1.80×). Paired wall: Binarytrees −2.1% and JsonParseSerializable
−5.1% beyond the spread (peak −8.3%), JsonParsePull peak −9.0%, Knuckeotide
peak −12.9%.

Kemal: `/json` 117.1% [104.2, 121.1] of Boehm at 1.38× (0.38.0: 112.7%,
1.39×), paired +6.0% [−4.3, +8.0]; `/` 104.8% [101.1, 110.7] at 1.39×
(0.38.0: 103.9%, 1.41×), paired +5.1% [−2.1, +8.5].
