# 0.39 against 0.38.0 and Boehm on GitHub's runners (2026-10-24)

`perf-ab.yml` run **39944941478**, all five runners: `var` = 0.39's `src/` at
`b888ac96`, `base` = `v0.38.0`, stock Crystal 1.21.0 (Boehm), plus a 16-byte
pad arm of each tree (`prepad16`, `baseprepad16`), process-fresh, interleaved
in random order per rep. crystal-metric 15 reps of the nine benches; Kemal
`/json` and `/` 15 trials (`wrk -t2 -c50`, 10 s after a 3 s warm-up) on the
four Linux/macOS runners. The files here are the run's artifacts as
downloaded: `{x86,arm64}-summary.md` (the numbers), `-runs.json`,
`-gc-counters.txt`, `-kemal-*`. Per-platform notes:
`bench/log/macos/2026-10-24-0.39-runners/FINDINGS.md`,
`bench/log/windows/2026-10-24-0.39-runners/FINDINGS.md`.

The release tip's one `src/` change since `b888ac96` (f23c99af) adds a
research hook to the after-world sweep, unset by default and tested once per
dropped chunk, so [INFERENCE] these numbers stand for the release.

The keep-rule reading of this run is
`../2026-10-22-0.39-keep-rule/FINDINGS.md` "Round 3".

## Summary

- Knuckeotide's peak falls on every runner (the slow-path stack wipe):
  `var` against `base`, paired, −9.4% `ubuntu-latest` (1.45× → 1.35× Boehm),
  −22.1% arm64 (1.28× → 1.14×), −16.4% M1 (1.59× → 1.33×), −12.9% Intel
  (1.80× → 1.56×), −3.2% [−6.7, +7.8] Windows (1.57× → 1.52×, within the
  spread). Every other row on every runner is within 1.1× Boehm's peak.
- Binarytrees faster beyond the spread on M1 (−5.4% wall), Intel (−2.1%) and
  arm64 (−4.3%).
- macOS (both), arm64 and Windows: no crystal-metric wall time slower than
  0.38.0 beyond its spread.
- `ubuntu-latest`: six rows slower in wall time beyond the spread
  (Binarytrees +3.8%, RegexDna +2.5%, JsonParseSerializable +2.3%,
  JsonParsePull +2.2%, Revcomp +1.5%, JsonParsePure +1.0%); 0.38.0 padded by
  16 bytes reads what 0.39 reads on all six, so [INFERENCE] placement (the
  keep-rule file's Round 3).
- Kemal `/json`, `var` against `base` paired per trial, median [IQR]:
  `ubuntu-latest` −0.7% [−3.8, +0.9], arm64 +1.3% [−2.4, +3.1], M1 +2.0%
  [−3.2, +13.5], Intel +6.0% [−4.3, +8.0]: level; peaks within ±0.6%.
  Kemal `/` on M1 is the one Kemal row slower beyond its spread: −7.0%
  [−25.6, −0.5] (see the macOS file).

## Linux x86_64 `ubuntu-latest` (4 vCPUs)

crystal-metric, speed % of Boehm / peak × Boehm, 0.39 (0.38.0): Primes 87%
(86%) / 0.93×, JsonParsePure 86% (88%) / 0.80×, Binarytrees 98% (101%) /
0.74×, JsonGenerate 86% (85%) / 0.62×, JsonParseSerializable 89% (91%) /
0.81× (0.76×), JsonParsePull 89% (91%) / 0.85× (0.83×), Revcomp 84% (86%) /
0.63×, RegexDna 90% (92%) / 0.54×, Knuckeotide 88% (88%) / 1.35× (1.45×).
JsonParseSerializable's peak +5.0% [+1.2, +9.8] paired, at 0.81× Boehm.

Kemal: `/json` 106.4% [103.7, 109.8] of Boehm at 1.23× (0.38.0: 108.3%,
1.14×; the peak ratio's IQR is 1.09–1.25 in both, 18.8 against 16.5 MiB);
`/` 101.3% [99.1, 104.8] (0.38.0: 101.6%), paired −0.5% [−2.1, +2.9].

## Linux arm64 `ubuntu-24.04-arm`

crystal-metric, 0.39 (0.38.0): Primes 101% (100%) / 0.93×, JsonParsePure 92%
(91%) / 1.07× (1.08×), Binarytrees 97% (92%) / 0.73×, JsonGenerate 100%
(98%) / 0.63×, JsonParseSerializable 100% (101%) / 0.86× (0.85×),
JsonParsePull 101% (101%) / 0.86× (0.85×), Revcomp 99% (99%) / 0.77×,
RegexDna 99% (99%) / 0.55×, Knuckeotide 91% (91%) / 1.14× (1.28×). Paired
wall: Binarytrees −4.3%, JsonParsePure −1.9%, JsonGenerate −2.0% beyond the
spread; JsonParseSerializable and JsonParsePull peaks +1.4% and +1.6% beyond
it, at 0.86× Boehm.

Kemal: `/json` 109.7% [106.4, 111.9] of Boehm at 1.33× (0.38.0: 109.4%,
1.33×); `/` 99.6% [98.8, 104.7] at 1.34× (0.38.0: 100.7%), paired +0.1%
[−2.2, +1.9].
