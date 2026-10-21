# 0.38 against 0.37.0 and Boehm on GitHub's runners (2026-10-21)

`perf-ab.yml` dispatched on branch `perf-038-runners` at 8b9e7eab (identical to origin/release-0.38.0 then): `var` = 0.38's `src/`, `base` = `v0.37.0`, stock Crystal 1.21.0 (Boehm) as the third arm, process-fresh, interleaved in random order per rep. crystal-metric 15 reps of Primes JsonParsePure Binarytrees JsonGenerate JsonParseSerializable JsonParsePull Revcomp RegexDna Knuckeotide; Kemal `/json` and `/` 15 trials, `wrk -t2 -c50` 10 s after 3 s warm-up (not on Windows: no `wrk`); `stats=3` counter runs (`*-gc-counters.txt`).

Measured at 8b9e7eab. The release tip has since moved to 70949577; its one `src/` change (69bd6a2e) affects only the in-stop sweep when a frozen thread holds the chunk list lock, not the default lazy sweep these benches run, so [INFERENCE] these numbers stand for the release.

Runs: 39487147696 (all five runners), 39497374362 (`macos-15-intel` and `windows-latest` repeat: Intel JsonGenerate and Windows Primes/Knuckeotide wall were slower beyond their spread in the first run). No job was cancelled. Per-runner tables: this file (Linux), `bench/log/macos/2026-10-21-0.38-runners/FINDINGS.md`, `bench/log/windows/2026-10-21-0.38-runners/FINDINGS.md`.

Cells: speed as % of Boehm (whole-process wall, Boehm/arm) and peak memory × Boehm (Linux VmHWM, macOS `ru_maxrss`, Windows PeakWorkingSetSize), medians of per-rep paired ratios [IQR]; the last five columns are 0.38 against 0.37.0 paired per rep (negative time = faster; Σ mark and collections from the per-run counters). Kemal: req/s % of Boehm / peak × Boehm (gcry peak), medians of per-trial paired ratios [IQR]; then 0.38 against 0.37.0 paired per trial, and collections per 1 000 requests from `/gc-stats`. Absolute % of Boehm differs between runner hosts; read each run against its own Boehm arm.

## Summary

- Binarytrees is faster on every runner: wall −14.7% on arm64 Linux (77% → 90% of Boehm), −3.9% on `ubuntu-latest` (90% → 94%), −11.2% and −12.3% on macOS Intel (133% → 149%, 129% → 149%), −3.8% on M1 (88% → 92%), −1.1% and −2.3% on Windows (level, 117–122%); 6–8% fewer collections on Linux and Intel.
- JsonParseSerializable / JsonParsePull: −3.4% / −2.9% wall on arm64, −2.1% / −1.8% on M1 (peak −7%, Σ mark −26–28%), −3.0% / −3.6% wall on Windows run 1 (level in run 2).
- Knuckeotide: 2–4% faster wall on both Linux runners and M1, level on Intel and Windows; its peak rises on Linux (below).
- RegexDna's peak falls 16–19% on `ubuntu-latest`, M1 and Intel run 1 (0.63× → 0.51×, 0.51× → 0.43×).
- Kemal is level on all four Linux/macOS runners (paired `/json` −0.3% to +4.1%, every IQR spanning 0 or positive); peak unchanged, the same collections per request.

## Rows where 0.38 is slower or heavier than 0.37.0 beyond its spread

- **Knuckeotide peak on Linux**: +17.8% [+8.2, +41.4] on `ubuntu-latest` (1.29× → 1.59× Boehm), +15.1% [+1.8, +40.7] on arm64 (1.08× → 1.35×), while its wall is 2.5–4.0% faster and Σ mark 23–29% lower. This is the dead buffer pinned from crystal-metric's own `Benchmark::run` frame named in the occupancy-claim entry (`bench/log/linux/2026-10-19-occupancy-claim-038/`). M1 +1.2% [+0.9, +1.2] (1.56× → 1.58×); Intel and Windows within the spread (Windows 1.64× → 1.77× and 1.55× → 1.71×, paired +2.0% [−0.3, +17.7] and −1.7% [−5.3, +13.4]).
- JsonGenerate's timed section on `ubuntu-latest`: +2.2% [+1.7, +3.9]; whole-process wall −0.5% [−1.7, +0.2], level.
- Revcomp wall on arm64: +0.5% [+0.2, +0.7] (timed +0.3% [−0.5, +0.9]).
- Peaks, small: JsonParsePure +0.6% [+0.5, +0.7] on `ubuntu-latest`; JsonParseSerializable +0.9% [+0.4, +1.2] and JsonParsePull +0.9% [+0.5, +1.1] on arm64 (all at or under 0.87× Boehm except JsonParsePure on arm64, 1.07×, unchanged); JsonParsePure +0.3% [+0.1, +0.6] on Windows run 1 (1.07×; level in run 2).
- Σ mark, at the same collection count: JsonGenerate +2.4% [+0.8, +2.9] and Primes +1.1% [+0.3, +1.5] on arm64, JsonParsePure +1.3% [+0.8, +2.5] on `ubuntu-latest`, RegexDna +4.8% [+0.3, +9.5] on Windows run 1 (one more collection, +4.3%, in both Windows runs); no wall cost beyond the spread except as listed.
- macOS Intel run 1 JsonGenerate: timed +7.8% [+3.4, +15.6], wall +4.2% [+1.2, +8.8]; run 2 timed +0.1% [−2.2, +8.5], wall −1.4% [−3.6, +1.4]: did not repeat.
- Windows run 1 wall: Primes +2.7% [+0.3, +6.2], Knuckeotide +2.6% [+0.8, +5.6], RegexDna +0.8% [+0.3, +2.3] (timed +0.8% [+0.4, +1.5]); run 2: +0.3% [−1.8, +2.6], +0.6% [−0.7, +2.3], +0.5% [−1.2, +1.7], level.
- M1 Revcomp: Σ mark +6.0% [−0.0, +11.6] with +3.7% [+1.9, +5.7] collections; wall −0.7% [−1.1, +2.8], level.

No Kemal row is slower or heavier than 0.37.0 beyond its spread on any runner.

## Linux x86_64 `ubuntu-latest`

Run 39487147696; raw `x86-summary.md`, `x86-runs.json`, `x86-kemal-*`, `x86-gc-counters.txt`.

| bench | Boehm | 0.37.0 speed / peak | 0.38 speed / peak | 0.38 vs 0.37.0: timed | wall | peak | Σ mark | collections |
|---|---:|---|---|---:|---:|---:|---:|---:|
| Primes | 1.267 s, 667 MiB | 90% [89, 90] / 0.93× [0.93, 0.93] | 90% [89, 91] / 0.93× [0.93, 0.93] | -0.7% [-1.7%, +1.3%] | -0.7% [-1.7%, +1.5%] | -0.0% [-0.0%, +0.0%] | -0.4% [-0.8%, +1.1%] | +0.0% [+0.0%, +0.0%] |
| JsonParsePure | 1.386 s, 692 MiB | 88% [88, 89] / 0.81× [0.80, 0.81] | 89% [88, 90] / 0.81× [0.81, 0.82] | -1.5% [-2.0%, -0.7%] | -0.6% [-1.3%, -0.4%] | +0.6% [+0.5%, +0.7%] | +1.3% [+0.8%, +2.5%] | +0.0% [+0.0%, +0.0%] |
| Binarytrees | 0.916 s, 50 MiB | 90% [88, 91] / 0.74× [0.73, 0.74] | 94% [92, 95] / 0.74× [0.74, 0.74] | -3.9% [-5.8%, -2.5%] | -3.9% [-5.9%, -2.5%] | -0.1% [-0.1%, +0.1%] | -0.8% [-12.7%, +19.5%] | -6.0% [-7.5%, -0.5%] |
| JsonGenerate | 2.373 s, 1310 MiB | 86% [85, 87] / 0.63× [0.58, 0.66] | 87% [86, 88] / 0.62× [0.58, 0.66] | +2.2% [+1.7%, +3.9%] | -0.5% [-1.7%, +0.2%] | -0.0% [-0.0%, +0.0%] | -1.0% [-9.4%, +0.5%] | +0.0% [-7.1%, +0.0%] |
| JsonParseSerializable | 1.435 s, 580 MiB | 92% [91, 92] / 0.73× [0.72, 0.77] | 92% [91, 93] / 0.73× [0.73, 0.79] | -2.4% [-2.7%, +1.1%] | -0.1% [-0.5%, +0.5%] | +0.8% [-0.1%, +1.1%] | +1.0% [-3.5%, +1.8%] | +0.0% [+0.0%, +7.7%] |
| JsonParsePull | 1.426 s, 543 MiB | 92% [92, 93] / 0.79× [0.77, 0.81] | 92% [91, 92] / 0.79× [0.77, 0.85] | -0.9% [-1.8%, -0.5%] | +0.7% [-0.3%, +1.6%] | +0.8% [-0.2%, +1.5%] | -0.8% [-2.2%, +2.3%] | +0.0% [-7.1%, +0.0%] |
| Revcomp | 2.988 s, 835 MiB | 85% [85, 85] / 0.63× [0.59, 0.67] | 85% [84, 85] / 0.63× [0.59, 0.67] | -0.2% [-1.1%, +0.4%] | +0.4% [-0.1%, +0.6%] | +0.0% [-0.0%, +0.0%] | +3.1% [-3.6%, +8.2%] | +0.0% [+0.0%, +0.0%] |
| RegexDna | 2.783 s, 426 MiB | 91% [91, 91] / 0.63× [0.52, 0.70] | 92% [92, 93] / 0.51× [0.42, 0.57] | -2.4% [-2.6%, -2.3%] | -1.8% [-1.9%, -1.6%] | -19.4% [-19.4%, -19.4%] | +2.5% [-2.3%, +6.4%] | +0.0% [+0.0%, +0.0%] |
| Knuckeotide | 1.117 s, 44 MiB | 90% [89, 91] / 1.29× [1.10, 1.40] | 93% [91, 94] / 1.59× [1.39, 1.70] | -2.9% [-3.9%, -1.2%] | -2.5% [-3.5%, -1.0%] | +17.8% [+8.2%, +41.4%] | -28.9% [-33.6%, -24.9%] | -5.7% [-7.7%, -1.4%] |

Kemal, 15 trials:

| path | 0.37.0 req/s % / peak × Boehm | 0.38 req/s % / peak × Boehm | 0.38 vs 0.37.0 req/s | peak | collections / 1k req (0.37.0 → 0.38) |
|---|---|---|---:|---:|---:|
| `/json` | 107.4% [105.1, 109.4] / 1.23× [1.10, 1.24] (19.0 MiB) | 107.9% [106.1, 108.4] / 1.23× [1.05, 1.25] (19.0 MiB) | +0.3% [-1.4%, +1.3%] | -0.2% [-0.7%, +0.1%] | 0.710 → 0.710 |
| `/` | 102.7% [101.2, 104.0] / 1.07× [1.04, 1.29] (19.0 MiB) | 101.5% [100.5, 103.9] / 1.17× [1.05, 1.29] (19.0 MiB) | -0.8% [-1.8%, +1.1%] | -0.2% [-0.3%, +0.3%] | 0.153 → 0.153 |

## Linux arm64 `ubuntu-24.04-arm`

Run 39487147696; raw `arm64-summary.md`, `arm64-runs.json`, `arm64-kemal-*`, `arm64-gc-counters.txt`.

| bench | Boehm | 0.37.0 speed / peak | 0.38 speed / peak | 0.38 vs 0.37.0: timed | wall | peak | Σ mark | collections |
|---|---:|---|---|---:|---:|---:|---:|---:|
| Primes | 1.172 s, 664 MiB | 96% [95, 99] / 0.93× [0.93, 0.93] | 99% [98, 100] / 0.93× [0.93, 0.93] | -2.0% [-3.0%, +0.3%] | -1.7% [-2.8%, +0.2%] | +0.0% [-0.0%, +0.0%] | +1.1% [+0.3%, +1.5%] | +0.0% [+0.0%, +0.0%] |
| JsonParsePure | 1.533 s, 515 MiB | 90% [89, 91] / 1.07× [1.07, 1.07] | 91% [90, 91] / 1.07× [1.07, 1.08] | -2.2% [-2.4%, -1.9%] | -0.9% [-1.2%, -0.6%] | +0.0% [-0.0%, +0.1%] | -0.8% [-1.4%, -0.1%] | +0.0% [+0.0%, +0.0%] |
| Binarytrees | 1.011 s, 50 MiB | 77% [76, 79] / 0.73× [0.73, 0.73] | 90% [89, 92] / 0.73× [0.73, 0.73] | -14.7% [-15.7%, -14.0%] | -14.7% [-15.8%, -13.9%] | -0.3% [-0.3%, -0.3%] | +14.1% [-19.9%, +47.6%] | -6.0% [-9.0%, -0.9%] |
| JsonGenerate | 2.731 s, 1174 MiB | 96% [95, 96] / 0.66× [0.63, 0.66] | 96% [96, 97] / 0.66× [0.63, 0.66] | -0.2% [-0.4%, +0.4%] | -0.8% [-1.1%, -0.0%] | -0.0% [-0.0%, -0.0%] | +2.4% [+0.8%, +2.9%] | +0.0% [+0.0%, +0.0%] |
| JsonParseSerializable | 1.653 s, 498 MiB | 97% [97, 98] / 0.84× [0.83, 0.86] | 100% [100, 101] / 0.84× [0.84, 0.87] | -4.9% [-5.3%, -4.7%] | -3.4% [-3.7%, -2.9%] | +0.9% [+0.4%, +1.2%] | -23.2% [-23.7%, -22.3%] | +6.7% [+6.7%, +6.7%] |
| JsonParsePull | 1.634 s, 483 MiB | 97% [97, 97] / 0.87× [0.84, 0.88] | 100% [100, 101] / 0.87× [0.85, 0.89] | -4.3% [-4.4%, -3.9%] | -2.9% [-3.5%, -2.6%] | +0.9% [+0.5%, +1.1%] | -23.2% [-23.8%, -22.7%] | +7.1% [+7.1%, +7.1%] |
| Revcomp | 3.095 s, 668 MiB | 99% [99, 100] / 0.78× [0.70, 0.79] | 99% [98, 99] / 0.76× [0.64, 0.79] | +0.3% [-0.5%, +0.9%] | +0.5% [+0.2%, +0.7%] | -3.3% [-3.3%, -3.3%] | +2.7% [-1.7%, +8.2%] | +0.0% [+0.0%, +3.6%] |
| RegexDna | 3.153 s, 400 MiB | 98% [98, 99] / 0.54× [0.42, 0.55] | 99% [98, 99] / 0.54× [0.42, 0.55] | -0.2% [-0.3%, -0.2%] | +0.1% [-0.1%, +0.2%] | -0.1% [-0.1%, -0.1%] | +4.4% [-0.5%, +7.6%] | +0.0% [+0.0%, +0.0%] |
| Knuckeotide | 1.185 s, 46 MiB | 87% [86, 88] / 1.08× [1.02, 1.31] | 90% [90, 91] / 1.35× [1.06, 1.49] | -4.3% [-4.9%, -3.1%] | -4.0% [-4.6%, -2.7%] | +15.1% [+1.8%, +40.7%] | -23.3% [-26.9%, -21.9%] | -1.4% [-6.8%, +1.4%] |

Kemal, 15 trials:

| path | 0.37.0 req/s % / peak × Boehm | 0.38 req/s % / peak × Boehm | 0.38 vs 0.37.0 req/s | peak | collections / 1k req (0.37.0 → 0.38) |
|---|---|---|---:|---:|---:|
| `/json` | 102.0% [99.4, 105.6] / 1.33× [1.06, 1.33] (18.1 MiB) | 103.8% [100.8, 106.8] / 1.32× [1.06, 1.33] (18.1 MiB) | +0.9% [-1.4%, +2.7%] | -0.3% [-0.4%, -0.3%] | 0.710 → 0.710 |
| `/` | 98.3% [95.6, 100.0] / 1.35× [1.34, 1.35] (18.3 MiB) | 100.1% [99.6, 101.9] / 1.34× [1.34, 1.35] (18.2 MiB) | +2.0% [+0.2%, +5.7%] | -0.3% [-0.4%, -0.3%] | 0.153 → 0.153 |
