# 0.39 against 0.38.0 and Boehm on GitHub's `windows-latest` runner (2026-10-24)

Same dispatch and method as `bench/log/linux/2026-10-24-0.39-runners/FINDINGS.md`
(run 39944941478, `var` = 0.39 at `b888ac96`, `base` = `v0.38.0`, Boehm =
stock Crystal 1.21.0, 16-byte pad arms), which holds the cross-runner
summary. Memory is PeakWorkingSetSize. No Kemal (the runner has no `wrk`).
Raw: `x86-summary.md` (the numbers), `x86-runs.json`, `x86-gc-counters.txt`.
One run.

| bench | Boehm | 0.38.0 speed / peak | 0.39 speed / peak | 0.39 vs 0.38.0: timed | wall | peak |
|---|---:|---|---|---:|---:|---:|
| Primes | 1.320 s, 666 MiB | 101% / 0.93× | 101% [95, 104] / 0.93× | +3.8% [−5.9, +10.7] | +2.8% [−5.2, +10.2] | −0.1% |
| JsonParsePure | 1.584 s, 518 MiB | 97% / 1.08× | 99% [97, 103] / 1.07× | −3.0% [−6.2, −2.5] | −3.5% [−5.9, −0.5] | −0.2% |
| Binarytrees | 1.480 s, 44 MiB | 131% / 0.92× | 130% [122, 146] / 0.92× | −1.9% [−3.0, +0.9] | +0.3% [−3.8, +4.1] | +0.0% |
| JsonGenerate | 2.765 s, 1335 MiB | 100% / 0.58× | 101% [99, 103] / 0.58× | −2.1% [−3.6, −1.5] | −1.6% [−3.0, +1.8] | −0.0% |
| JsonParseSerializable | 1.574 s, 555 MiB | 99% / 0.80× | 104% [100, 106] / 0.81× | −0.6% [−2.9, +1.3] | −1.7% [−7.9, +1.3] | +1.0% |
| JsonParsePull | 1.587 s, 555 MiB | 103% / 0.81× | 105% [104, 107] / 0.81× | −2.3% [−3.0, −1.4] | −2.3% [−4.4, −0.5] | −0.8% |
| Revcomp | 3.503 s, 895 MiB | 99% / 0.61× | 105% [103, 108] / 0.59× | +3.3% [+1.7, +4.0] | −5.0% [−6.7, −4.0] | −3.7% |
| RegexDna | 4.142 s, 527 MiB | 100% / 0.47× | 103% [101, 104] / 0.43× | −0.2% [−0.9, +0.6] | −2.3% [−4.0, −1.5] | −7.3% [−7.3, +0.9] |
| Knuckeotide | 1.318 s, 52 MiB | 100% / 1.57× | 102% [99, 107] / 1.52× | −0.2% [−1.8, +2.0] | −0.8% [−4.6, +1.1] | −3.2% [−6.7, +7.8] |

crystal-metric runs at 99–130% of Boehm's speed (0.38.0 in the same run:
97–131%), peak working set 0.43–0.93× on 7 of 9 rows; JsonParsePure 1.07×
and Knuckeotide 1.52× [1.38, 1.72] (0.38.0: 1.57×, paired within the spread)
are the two above Boehm. No wall time is slower than 0.38.0 beyond its
spread; JsonParsePure, JsonParsePull, Revcomp and RegexDna are faster beyond
it. Revcomp's timed section is +3.3% [+1.7, +4.0] while its whole-process
wall is −5.0%: the row whose speed follows code placement on these runners
(`../2026-10-16-revcomp-attribution/`); 0.39 padded by 16 bytes reads +1.3%
[+0.3, +3.0] against unpadded 0.39 in the timed section.
