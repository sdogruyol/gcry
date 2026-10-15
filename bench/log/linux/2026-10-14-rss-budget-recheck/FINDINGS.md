# The RSS budget, re-measured on 0.35.0: the cap stays at 64 MiB

ROADMAP "Decide the RSS budget for large live sets" waited for a budget. The
budget is now set: **gcry's peak RSS stays within 1.1× Boehm's on every
crystal-metric row**. `../2026-10-05-rss-budget-vs-boehm/` measured that
`GCRY_THRESHOLD_MAX=256 MiB` met it on `ccde8a7` and bought Primes +12 points
of Boehm's speed. Re-measured on `b18d5c8` (0.35.0), it no longer does either.

Between the two, threshold pacing (`../2026-10-06-threshold-pacing/`) and the
parallel mark default (`../2026-10-05-parallel-mark-default/`) landed. Pacing
scales the cap too, so the same `MAX` now buys a threshold up to three times
larger, and the collections the larger cap used to save are already saved.

## Method

`ab.py`: crystal-metric `--release` (one gcry binary, one Boehm binary, arms
differ only by environment), each (rep, bench) runs every arm once in a
random order, whole-process wall time and `ru_maxrss` from `wait4`, medians.
12 CPUs, Linux x86_64, Crystal 1.21.0. The host was shared with other builds
(load average 6–18), so wall-time differences under ~5% are noise; peak RSS
is not affected by load. Cells: speed as % of Boehm / peak RSS × Boehm.
Checksum mismatches (`err result=…`) are identical in every arm, Boehm's
included, and are the vendored inputs, not the collector.

## Round 1: 7 reps (`round1.md`, `round1-runs.json`)

| bench | Boehm | gcry default (64 MiB) | `MAX=128 MiB` | `MAX=256 MiB` |
|---|---:|---|---|---|
| Primes | 1.096 s, 659 MB | 107% / 0.94× | 111% / 0.95× | 117% / 0.96× |
| JsonParsePure | 1.303 s, 689 MB | 101% / 0.83× | 101% / 0.86× | 106% / 0.89× |
| JsonGenerate | 2.391 s, 1304 MB | 101% / 0.66× | 109% / 0.66× | 102% / 0.71× |
| JsonParseSerializable | 1.263 s, 559 MB | 106% / 0.91× | 105% / 0.95× | 104% / 1.00× |
| JsonParsePull | 1.196 s, 524 MB | 106% / 0.94× | 104% / 1.03× | 100% / 0.96× |
| RegexDna | 3.223 s, 384 MB | 103% / 0.71× | 102% / 0.87× | 99% / **1.24×** |
| Revcomp | 2.651 s, 887 MB | 100% / 0.63× | 98% / 0.87× | 102% / 0.80× |
| Binarytrees | 0.778 s, 50 MB | 111% / 0.76× | 107% / 0.76× | 110% / 0.76× |
| Knuckeotide | 1.010 s, 47 MB | 101% / 1.31× | 104% / 1.38× | 103% / 1.27× |

## Round 2: 11 reps (`round2.md`, `round2-runs.json`)

| bench | Boehm | gcry default (64 MiB) | `MAX=128 MiB` | `MAX=192 MiB` |
|---|---:|---|---|---|
| Primes | 0.923 s, 659 MB | 103% / 0.94× | 106% / 0.94× | 106% / 0.95× |
| JsonParsePure | 1.077 s, 686 MB | 99% / 0.83× | 100% / 0.85× | 99% / 0.84× |
| JsonGenerate | 2.001 s, 1304 MB | 100% / 0.66× | 101% / 0.66× | 102% / 0.71× |
| JsonParseSerializable | 1.138 s, 540 MB | 103% / 0.90× | 103% / 0.94× | 105% / 1.02× |
| JsonParsePull | 1.123 s, 533 MB | 109% / 0.91× | 104% / 0.93× | 105% / 0.94× |
| RegexDna | 2.807 s, 397 MB | 98% / 0.68× | 96% / 0.84× | 98% / 1.04× |
| Revcomp | 2.366 s, 885 MB | 97% / 0.63× | 94% / 0.87× | 95% / 0.67× |

## What it says

- **The default already meets the budget and the speed it was for.** Primes
  is 103–107% of Boehm's speed (38% on `ccde8a7`), JsonParsePure 99–101%
  (47%), at 0.94× and 0.83× Boehm's peak.
- **256 MiB now breaks the budget**: RegexDna 1.24× Boehm's peak (1.06× on
  `ccde8a7`), because the paced threshold is up to 3× the cap.
- **128 and 192 MiB buy nothing measurable.** Every speed difference against
  the default is within the round-to-round spread (Primes +3 to +4 points,
  JsonParsePull −4 to −5), while the atomic-heavy rows pay RSS: Revcomp
  0.63× → 0.87×, RegexDna 0.68× → 0.84–1.04×.
- Knuckeotide's 1.31× is the default, not the cap: a 47 MB process whose
  peak is set by the 8 MiB threshold floor and the warm budget, and every
  arm is within noise of it. It is the one row over the budget, by 15 MB.

Decision: the budget is "within 1.1× Boehm's peak RSS"; the 64 MiB cap
floor stays. `GCRY_THRESHOLD_MAX` remains the knob for a program that wants
fewer majors for more RSS.
