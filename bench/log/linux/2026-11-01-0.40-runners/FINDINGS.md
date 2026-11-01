# 0.40 against 0.39.0 and Boehm on GitHub's runners (2026-11-01)

`perf-ab.yml` run **41253485376**, all five runners, dispatched on
`release-0.40.0` at `69bfcaf2` (`src/` as at `2c600dfb`): `var` = 0.40's
`src/`, `base` = `v0.39.0`, stock Crystal 1.21.0 (Boehm), plus a 16-byte pad
arm of each tree (`prepad16`, `baseprepad16`), process-fresh, interleaved in
random order per rep. crystal-metric 15 reps of the nine benches, `stats=3`;
Kemal `/json` and `/` 15 trials (`wrk -t2 -c50`, 10 s after a 3 s warm-up) on
the four Linux/macOS runners. The inputs of 0.39's run 39944941478
(`../2026-10-24-0.39-runners/`). The files here are the run's artifacts as
downloaded: `{x86,arm64}-summary.md` (the numbers), `-runs.json`,
`-gc-counters.txt`, `-kemal-*`; `keep.txt` is
`../2026-11-01-0.40-keep-rule/keep.py` over the run. Per-platform notes:
`bench/log/macos/2026-11-01-0.40-runners/FINDINGS.md`,
`bench/log/windows/2026-11-01-0.40-runners/FINDINGS.md`.

The keep-rule reading of 0.40, with two pad arms a side and the attribution
probes, is `../2026-11-01-0.40-keep-rule/FINDINGS.md`; this run is the
numbers for the docs, one pad a side as 0.39's was.

## Summary

- **Linux (both) and M1: no row slower than 0.39.0 that a 0.40 pad arm does
  not read inside 0.39.0's**, except arm64 JsonGenerate (+1.1% wall), the
  fifteenth collection (below and the keep-rule file's §4).
- **Intel Primes +7.6% wall [+3.9, +14.7] and Windows Primes +6.3% [+1.6,
  +9.0] sit on a collection-count step.** Primes collects 9 or 10 times on
  both runners, and a run with 10 is slower whichever tree it is: 16–21% on
  Intel, 3–4% on Windows. Here 0.40 collected 10 times in 11 of 15 runs on
  each, 0.39.0 in 4 (Intel) and 6 (Windows) of 15, and 0.39.0 padded by 16
  bytes in 11 (Intel) and 0 (Windows) of 15. At equal counts Intel is level
  (9: 2.095 against 2.155 s; 10: 2.541 against 2.493 s); Windows read 2–3%
  slower here (9: 1.526 against 1.491 s; 10: 1.586 against 1.537 s) and level
  at equal counts and the same code phase with four pads a side
  (`../../windows/2026-11-02-0.40-win-rows/` §3). The two earlier 0.40 runs (`9dc77af5` and `2c600dfb`) read
  Intel Primes +3.5% [+0.7, +10.5] and +3.5% [−1.5, +6.8] with 0.39.0 padded
  at 10 collections in 13 of 15 runs both times, and Windows Primes within
  its spread (keep-rule §1, §6). [INFERENCE] the pace step the keep-rule
  file's §4 finds for arm64 JsonGenerate: a cheaper cycle lowers the paced
  threshold enough for one more collection. On a Windows EPYC 7763 the tip
  without the mark unroll reaches the tenth about halfway between 0.40 and
  0.39.0 (`../../windows/2026-11-02-0.40-win-rows/` §3).
- **Windows:** seven rows slower in wall time beyond the spread, Revcomp
  +7.3% the largest; with one pad a side only JsonGenerate's is inside
  0.39.0's band here. All seven are placement: with the four 16-byte code
  phases of each tree in one session the trees read the same at the same
  phase, and 0.40 unpadded sits on a slow one
  (`../../windows/2026-11-02-0.40-win-rows/`). See the Windows file.
- **Peaks:** macOS JsonGenerate −13.6% on both Macs (0.74× → 0.64× M1, 0.75×
  → 0.65× Intel) and Intel Revcomp −11.7%, from the heap placed at 16–32 TiB
  (`bench/log/macos/2026-10-31-heap-high/`). Knuckeotide's peak is level with
  or below 0.39.0's on every runner (paired −2.8% to +0.4%). Every row
  but Knuckeotide is within 1.1× Boehm's peak on every runner (JsonParsePure
  1.07× on arm64 and Windows, both trees).
- **Σ mark:** lower on arm64 (JsonParsePure −7.2%, JsonParseSerializable
  −8.7%, JsonParsePull −8.6%), the mark loop unrolled by four (`cbf1b2e8`;
  keep-rule §4), and on M1 (Binarytrees −21.2% [−24.6, +0.9], Knuckeotide
  −16.0%, RegexDna −11.0%; [INFERENCE] the same change, not probed there);
  on `ubuntu-latest` Revcomp +13.3% and RegexDna +12.5% are the 0.5 → 0.6 ms
  of the keep-rule file's §5, with no wall time moving.
- **Kemal**, `var` against `base` paired per trial, median [IQR]: `/json`
  `ubuntu-latest` −1.3% [−4.0, +0.9], arm64 **+7.3% [+0.2, +8.0]**, M1 +3.9%
  [−8.8, +9.3], Intel +0.2% [−5.9, +9.3]; `/` +2.2% [+0.3, +4.1], +3.0%
  [+0.3, +4.5], +1.9% [−5.2, +7.7], +4.5% [−8.5, +13.8]. No Kemal row slower;
  peaks within −1.7% to +0.1%.

## Linux x86_64 `ubuntu-latest` (4 vCPUs)

crystal-metric, speed % of Boehm / peak × Boehm, 0.40 (0.39.0): Primes 108%
(109%) / 0.93×, JsonParsePure 106% (106%) / 0.80×, Binarytrees 106% (108%) /
0.74×, JsonGenerate 104% (105%) / 0.63×, JsonParseSerializable 106% (107%) /
0.78× (0.79×), JsonParsePull 105% (106%) / 0.84×, Revcomp 97% (97%) / 0.62×,
RegexDna 97% (97%) / 0.56×, Knuckeotide 94% (94%) / 1.42×. Slower beyond the
spread: JsonParseSerializable wall +0.6% [+0.1, +0.8], and in the timed
section JsonParsePure +0.9%, JsonParseSerializable +1.7%, JsonParsePull +1.6%;
0.40 padded by 16 bytes reads faster than both 0.39.0 arms on all three
(`keep.txt`). Knuckeotide −0.7% wall, faster.

Kemal: `/json` 103.8% [100.1, 106.6] of Boehm at 1.31× (0.39.0: 104.2%,
1.31×), paired −1.3% [−4.0, +0.9]; `/` 101.1% [99.9, 104.8] at 1.30× (0.39.0:
100.6%), paired +2.2% [+0.3, +4.1].

## Linux arm64 `ubuntu-24.04-arm`

crystal-metric, 0.40 (0.39.0): Primes 102% (104%) / 0.93×, JsonParsePure 93%
(93%) / 1.07×, Binarytrees 96% (97%) / 0.74× (0.73×), JsonGenerate 100%
(100%) / 0.63×, JsonParseSerializable 101% (100%) / 0.84× (0.85×),
JsonParsePull 101% (101%) / 0.84× (0.86×), Revcomp 99% (98%) / 0.69×,
RegexDna 99% (99%) / 0.42×, Knuckeotide 90% (90%) / 1.13× (1.14×). Paired
wall slower beyond the spread: Primes +1.8%, Binarytrees +1.2%, JsonGenerate
+1.1%, JsonParsePull +0.5%; Primes, Binarytrees and JsonParsePull have a 0.40
arm inside 0.39.0's band. JsonGenerate does not: 0.40 collected 15 times in
14 of 15 runs (`prepad16` 12 of 15), 0.39.0 14 times in 15 of 15
(`baseprepad16` 15 times in 3 of 15), the step of the keep-rule file's §4,
whose 21-rep session put the row inside 0.39.0's two-pad band. Revcomp −0.6%,
faster.

Kemal: `/json` 107.4% [105.1, 109.7] of Boehm at 1.32× (0.39.0: 103.0%,
1.32×), paired +7.3% [+0.2, +8.0], with 0.40 padded at 107.1% and 0.39.0
padded at 102.5%; `/` 102.2% [100.6, 105.9] at 1.34× (0.39.0: 99.6%), paired
+3.0% [+0.3, +4.5]. Not attributed.
