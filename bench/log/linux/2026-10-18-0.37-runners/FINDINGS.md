# 0.37.0 against 0.36.0 and Boehm on GitHub's runners (2026-10-18)

`perf-ab.yml` dispatched on branch `release-numbers-037` at 4b625c87 (origin/release-0.37.0 then): `var` = 0.37.0's `src/`, `base` = `v0.36.0`, stock Crystal 1.21.0 (Boehm) as the third arm, process-fresh, interleaved in random order per rep. crystal-metric 15 reps of Primes JsonParsePure Binarytrees JsonGenerate JsonParseSerializable JsonParsePull Revcomp RegexDna Knuckeotide; Kemal `/json` and `/` 15 trials, `wrk -t2 -c50` 10 s after 3 s warm-up (not on Windows: no `wrk`); `stats=3` counter runs.

Runs: 39056939449 (all five runners), 39061365549 (`macos-latest` repeat: wide IQRs in the first), 39061402497 (`ubuntu-latest` repeat: Kemal `/json` slower in the first). 39056914814 was a mis-set dispatch (5 Kemal trials), cancelled.

The release tip has since moved past 4b625c87; its `src/` differs only by the Monitor gate one-line change in `collect_stw.cr` (7a167ddf) and documentation, so [INFERENCE] these numbers stand for the release.

Cells: speed as % of Boehm (whole-process wall, Boehm/arm) and peak memory × Boehm (Linux VmHWM, macOS `ru_maxrss`, Windows PeakWorkingSetSize), medians of per-rep paired ratios [IQR]; the last three columns are 0.37 against 0.36.0 paired per rep (negative time = faster). Absolute % of Boehm differs between runner hosts: `ubuntu-latest` run 2 landed on a slower host (Boehm Primes 1.251 s against 0.843 s), so read each run against its own Boehm arm.

## Rows where 0.37 is slower than 0.36.0 beyond its spread

- **Kemal `/json` on Linux x86_64 (`ubuntu-latest`)**: −2.3% [−3.9, −0.6] (run 1), −6.6% [−8.0, −1.6] (run 2), and −2.4% [−4.8, −0.9] in a third, 20-trial run (39064871680); `/` +0.4% then −3.0% [−4.2, −0.2]. Peak −10%. Attribution below. The parent's local 12-CPU run had it at 115.6% against 116.4% of Boehm (−0.7%) in one session (`bench/log/linux/2026-10-18-0.37-kemal/`). Linux arm64 (+1.1% [−0.1, +4.8]) and both macOS runners are level or faster.
- Revcomp's timed section on `ubuntu-latest`: +2.9% [+2.1, +5.0] and +2.6% [+1.9, +3.0]; whole-process wall −2.4% in run 1, +1.5% [+1.1, +1.6] in run 2. On arm64 +0.7% [+0.0, +1.3] timed, wall level. Σ mark +16–20% with 27% more collections (the atomic quarter). Windows and macOS: faster or level.
- JsonParseSerializable / JsonParsePull timed sections on arm64: +1.2% [+0.9, +1.7], +0.8% [+0.5, +1.5] (wall −2.1%, −2.5%); JsonParseSerializable timed on `ubuntu-latest` run 2 +1.4% [+1.0, +1.8] (wall −1.9%). macOS arm64 run 2 JsonParsePull timed +1.0% [+0.0, +3.2], wall level.
- `ubuntu-latest` run 2 wall: Knuckeotide +0.7% [+0.1, +1.2], RegexDna +0.4% [+0.2, +0.5] (run 1: level and −1.4%).
- Primes' peak is +0.9–1.6% on every runner (one more collection, scheduled later).
- JsonGenerate's peak on `macos-latest` run 1: 0.64× → 0.73× (+20.3% [−0.0, +20.4]); level in run 2 (−0.0% [−1.8, +5.0]), so bimodal, not settled.
- Windows Knuckeotide peak 1.67× → 1.73×, +4.9% [−0.8, +17.5]: within the spread, with 14.7% more page faults.

No crystal-metric whole-process wall time is slower beyond its spread on macOS (either runner), Windows or Linux arm64.

## Kemal `/json` on `ubuntu-latest`: bisect

One paired run per pair, `ubuntu-latest` only, Kemal 20–25 trials (crystal-metric reduced to Binarytrees × 3), `src/` of each commit on top of 4b625c87's bench scripts (`probe-kemal-<sha>` branches, deleted afterwards; each probe commit is `src/` from that sha). Raw: `kemal-bisect/<run>-kemal-*`. The `src/` commits between v0.36.0 and 4b625c87: a4983b34 7d14cdb7 50b1315e ecb37a90 eda7680e a2cd00d0 ec551749 5a9d8312 75e7628e fa51f65f a975d5cd 272d73e5 dab25144 (= 4b625c87's `src/`).

| pair (var vs base) | run | `/json` req/s | `/` req/s | `/json` peak |
|---|---|---:|---:|---:|
| 50b1315e vs v0.36.0 | 39064857643 | -1.2% [-3.8, +0.5] | -1.0% [-2.6, +0.7] | +0.2% [-0.4, +0.5] |
| ec551749 vs 50b1315e | 39064859845 | -2.3% [-4.5, +3.2] | +0.3% [-2.5, +1.8] | -0.2% [-0.5, +0.0] |
| fa51f65f vs ec551749 | 39064862549 | +1.6% [-0.6, +3.6] | +0.6% [-1.2, +1.9] | -8.5% [-8.7, -8.1] |
| a975d5cd vs fa51f65f | 39064864725 | -2.5% [-3.1, +0.1] | +0.3% [-1.4, +1.6] | -2.5% [-2.8, -2.2] |
| 272d73e5 vs a975d5cd | 39064866844 | -1.5% [-5.0, +4.3] | -3.0% [-5.1, +1.7] | -0.0% [-0.2, +0.3] |
| tip vs 272d73e5 | 39064869344 | -0.9% [-2.5, +0.2] | +0.1% [-1.0, +1.3] | -0.1% [-0.3, +0.3] |
| tip vs v0.36.0 | 39064871680 | -2.4% [-4.8, -0.9] | +0.1% [-2.8, +2.3] | -10.3% [-10.9, -10.1] |
| a975d5cd vs fa51f65f (b) | 39067617862 | -4.1% [-6.1, -0.8] | -1.4% [-5.6, +1.2] | -2.5% [-3.0, -2.1] |
| a975d5cd vs fa51f65f (c) | 39067622934 | -3.0% [-4.9, -0.9] | -0.9% [-1.9, +0.4] | -2.7% [-3.0, -2.4] |
| fa51f65f vs v0.36.0 | 39067628575 | +0.4% [-2.4, +4.7] | -0.4% [-2.5, +2.4] | -8.4% [-8.7, -8.0] |
| tip vs a975d5cd | 39067634218 | +0.2% [-2.4, +3.9] | -1.3% [-2.4, +0.3] | -0.0% [-0.2, +0.3] |
| a975d5cd+pad vs a975d5cd (a) | 39070534332 | +0.1% [-1.8, +3.1] | +1.9% [-2.8, +4.6] | +2.6% [+2.5, +3.0] |
| a975d5cd+pad vs a975d5cd (b) | 39070540482 | +1.3% [-1.0, +4.6] | -0.3% [-2.3, +1.2] | +2.4% [+2.1, +2.8] |
| tip+pad vs tip (a) | 39070546226 | +2.9% [-1.7, +5.0] | +1.6% [-1.1, +4.1] | +2.2% [+2.1, +2.4] |
| tip+pad vs tip (b) | 39070551168 | +2.4% [-0.8, +5.2] | +1.3% [-1.4, +3.7] | +2.6% [+2.3, +2.9] |

Only a975d5cd (heap: research knobs' release tables mapped when armed, not carried in every `Heap`) is slower on three of three runners, beyond the spread on two (−4.1% [−6.1, −0.8], −3.0% [−4.9, −0.9]) and at its edge on the first (−2.5% [−3.1, +0.1]); the halves on either side are level (v0.36.0 → fa51f65f +0.4%, a975d5cd → tip +0.2%). It is not added work: it removes 472 KiB of `StaticArray`s from the `Heap` (−2.5% peak) and stops recording every chunk release into the release map, which ran by default before. Putting a 472 KiB dummy `StaticArray(UInt8, 483328)` back where the arrays were (`probe-kemal-layout-*`) moves `/json` +0.1% and +1.3% on a975d5cd and +2.9% and +2.4% on the tip, every IQR straddling zero, at +2.2–2.6% peak: [INFERENCE] part of it is where the `Heap`'s fields fall relative to each other after the shrink, the rest code placement in `collect.cr`; neither is a per-request cost that can be removed, and putting the 472 KiB back would undo 0.37.0's RSS gain for a gain inside the noise. No fix proposed.

## Per runner

### Linux x86_64 `ubuntu-latest`, run 1

Run 39056939449; raw `x86-r1-summary.md`, `x86-r1-runs.json`, `x86-r1-kemal-*`, `x86-r1-gc-counters.txt`.

| bench | Boehm | 0.36.0 speed / peak | 0.37 speed / peak | 0.37 vs 0.36.0: timed | wall | peak |
|---|---:|---|---|---:|---:|---:|
| Primes | 0.843 s, 666 MiB | 83% [81, 86] / 0.92× [0.92, 0.92] | 87% [85, 90] / 0.93× [0.93, 0.93] | -3.7% [-7.5%, -2.2%] | -3.5% [-7.2%, -2.1%] | +1.3% [+1.2%, +1.4%] |
| JsonParsePure | 1.112 s, 690 MiB | 87% [84, 87] / 0.81× [0.81, 0.82] | 88% [88, 89] / 0.81× [0.81, 0.81] | -1.1% [-2.1%, -0.2%] | -1.6% [-2.9%, -1.0%] | -0.2% [-0.4%, -0.1%] |
| Binarytrees | 0.717 s, 50 MiB | 85% [83, 90] / 0.75× [0.75, 0.75] | 86% [85, 88] / 0.74× [0.73, 0.74] | -0.4% [-2.2%, +0.5%] | -0.2% [-2.2%, +0.5%] | -2.2% [-2.3%, -2.0%] |
| JsonGenerate | 1.936 s, 1237 MiB | 85% [85, 86] / 0.62× [0.59, 0.63] | 88% [87, 88] / 0.62× [0.59, 0.63] | -3.1% [-3.6%, -2.1%] | -3.1% [-3.8%, -2.1%] | -0.1% [-0.1%, -0.0%] |
| JsonParseSerializable | 1.073 s, 581 MiB | 89% [87, 90] / 0.75× [0.72, 0.79] | 90% [88, 92] / 0.76× [0.74, 0.80] | +1.5% [-0.3%, +2.7%] | -2.0% [-3.7%, +0.1%] | +2.4% [-4.0%, +5.0%] |
| JsonParsePull | 1.070 s, 543 MiB | 89% [88, 91] / 0.79× [0.77, 0.82] | 91% [90, 92] / 0.79× [0.78, 0.85] | +1.1% [-0.6%, +1.9%] | -2.0% [-3.3%, +0.7%] | +2.0% [-0.4%, +2.5%] |
| Revcomp | 2.388 s, 849 MiB | 83% [83, 84] / 0.62× [0.59, 0.64] | 85% [84, 86] / 0.64× [0.59, 0.65] | +2.9% [+2.1%, +5.0%] | -2.4% [-2.9%, -0.2%] | -0.1% [-0.1%, -0.1%] |
| RegexDna | 2.270 s, 458 MiB | 90% [89, 91] / 0.59× [0.52, 0.75] | 91% [90, 93] / 0.59× [0.52, 0.69] | -1.1% [-1.7%, -0.4%] | -1.4% [-2.0%, -0.7%] | -0.4% [-0.4%, -0.4%] |
| Knuckeotide | 0.829 s, 47 MiB | 83% [81, 85] / 1.39× [1.24, 1.57] | 83% [82, 84] / 1.31× [1.14, 1.38] | +0.1% [-0.8%, +1.7%] | -0.1% [-1.3%, +1.0%] | -13.5% [-20.0%, +2.6%] |

Kemal, 15 trials (req/s % of Boehm / peak × Boehm (gcry peak), medians of per-trial paired ratios [IQR]; last two columns 0.37 against 0.36.0, paired per trial):

| path | 0.36.0 req/s % / peak × Boehm | 0.37 req/s % / peak × Boehm | 0.37 vs 0.36.0 req/s | peak |
|---|---|---|---:|---:|
| `/json` | 105.2% [103.2, 107.8] / 1.18× [1.12, 1.36] (21.1 MiB) | 102.9% [102.2, 103.7] / 1.06× [1.00, 1.23] (18.9 MiB) | -2.3% [-3.9%, -0.6%] | -10.4% [-10.6%, -10.2%] |
| `/` | 99.2% [98.8, 101.3] / 1.15× [1.13, 1.37] (20.4 MiB) | 100.5% [99.3, 101.3] / 1.06× [1.03, 1.26] (18.9 MiB) | +0.4% [-1.6%, +1.7%] | -7.7% [-8.0%, -7.5%] |

### Linux x86_64 `ubuntu-latest`, run 2

Run 39061402497; raw `x86-r2-summary.md`, `x86-r2-runs.json`, `x86-r2-kemal-*`, `x86-r2-gc-counters.txt`.

| bench | Boehm | 0.36.0 speed / peak | 0.37 speed / peak | 0.37 vs 0.36.0: timed | wall | peak |
|---|---:|---|---|---:|---:|---:|
| Primes | 1.251 s, 666 MiB | 82% [81, 83] / 0.92× [0.92, 0.92] | 84% [83, 85] / 0.93× [0.93, 0.93] | -2.2% [-2.6%, -1.2%] | -2.2% [-2.7%, -1.4%] | +0.9% [+0.9%, +1.1%] |
| JsonParsePure | 1.707 s, 685 MiB | 86% [85, 86] / 0.81× [0.80, 0.81] | 88% [87, 88] / 0.80× [0.80, 0.81] | -1.0% [-2.8%, -0.5%] | -2.0% [-2.3%, -1.5%] | -0.4% [-0.5%, -0.3%] |
| Binarytrees | 1.153 s, 50 MiB | 94% [93, 95] / 0.75× [0.75, 0.75] | 93% [92, 94] / 0.74× [0.73, 0.74] | +0.6% [-1.4%, +2.1%] | +0.5% [-1.4%, +2.1%] | -2.0% [-2.2%, -1.9%] |
| JsonGenerate | 2.925 s, 1235 MiB | 84% [84, 84] / 0.62× [0.59, 0.66] | 85% [84, 86] / 0.66× [0.61, 0.67] | -3.4% [-3.8%, -2.9%] | -1.6% [-2.4%, -1.0%] | +0.1% [-0.1%, +3.7%] |
| JsonParseSerializable | 1.801 s, 539 MiB | 89% [89, 90] / 0.79× [0.76, 0.81] | 91% [91, 91] / 0.78× [0.72, 0.79] | +1.4% [+1.0%, +1.8%] | -1.9% [-2.6%, -1.3%] | -2.3% [-3.6%, -1.7%] |
| JsonParsePull | 1.773 s, 543 MiB | 89% [88, 90] / 0.79× [0.77, 0.82] | 91% [90, 91] / 0.78× [0.76, 0.82] | -1.0% [-1.3%, +0.0%] | -2.1% [-3.0%, -1.6%] | -2.5% [-3.3%, +1.6%] |
| Revcomp | 3.630 s, 868 MiB | 85% [85, 86] / 0.61× [0.59, 0.64] | 84% [84, 84] / 0.61× [0.59, 0.64] | +2.6% [+1.9%, +3.0%] | +1.5% [+1.1%, +1.6%] | -0.1% [-0.1%, -0.1%] |
| RegexDna | 3.513 s, 431 MiB | 91% [90, 91] / 0.68× [0.55, 0.69] | 90% [90, 90] / 0.63× [0.53, 0.69] | -1.9% [-1.9%, -1.7%] | +0.4% [+0.2%, +0.5%] | -0.4% [-0.5%, -0.4%] |
| Knuckeotide | 1.285 s, 43 MiB | 88% [88, 89] / 1.40× [1.24, 1.58] | 88% [87, 88] / 1.38× [1.22, 1.43] | +0.8% [+0.2%, +1.4%] | +0.7% [+0.1%, +1.2%] | -1.7% [-12.4%, +1.5%] |

Kemal, 15 trials (req/s % of Boehm / peak × Boehm (gcry peak), medians of per-trial paired ratios [IQR]; last two columns 0.37 against 0.36.0, paired per trial):

| path | 0.36.0 req/s % / peak × Boehm | 0.37 req/s % / peak × Boehm | 0.37 vs 0.36.0 req/s | peak |
|---|---|---|---:|---:|
| `/json` | 110.8% [106.9, 113.1] / 1.37× [1.17, 1.40] (20.9 MiB) | 104.9% [100.5, 105.5] / 1.22× [1.05, 1.24] (18.7 MiB) | -6.6% [-8.0%, -1.6%] | -10.7% [-11.0%, -10.4%] |
| `/` | 104.8% [100.8, 108.1] / 1.36× [1.19, 1.41] (20.3 MiB) | 102.8% [100.9, 105.4] / 1.24× [1.11, 1.30] (18.7 MiB) | -3.0% [-4.2%, -0.2%] | -7.6% [-7.8%, -7.4%] |

### Linux arm64 `ubuntu-24.04-arm`

Run 39056939449; raw `arm64-summary.md`, `arm64-runs.json`, `arm64-kemal-*`, `arm64-gc-counters.txt`.

| bench | Boehm | 0.36.0 speed / peak | 0.37 speed / peak | 0.37 vs 0.36.0: timed | wall | peak |
|---|---:|---|---|---:|---:|---:|
| Primes | 1.330 s, 664 MiB | 92% [90, 95] / 0.92× [0.92, 0.92] | 100% [94, 102] / 0.93× [0.93, 0.93] | -6.0% [-9.0%, -3.6%] | -5.8% [-8.6%, -3.5%] | +1.6% [+1.6%, +1.6%] |
| JsonParsePure | 1.541 s, 515 MiB | 88% [87, 88] / 1.09× [1.08, 1.09] | 90% [89, 91] / 1.07× [1.07, 1.08] | -2.2% [-2.5%, -1.9%] | -2.8% [-2.9%, -2.3%] | -1.1% [-1.2%, -0.9%] |
| Binarytrees | 1.062 s, 50 MiB | 79% [77, 84] / 0.75× [0.75, 0.75] | 80% [77, 83] / 0.73× [0.73, 0.73] | +0.1% [-0.6%, +1.4%] | +0.0% [-0.6%, +1.4%] | -2.0% [-2.0%, -2.0%] |
| JsonGenerate | 2.788 s, 1227 MiB | 95% [94, 96] / 0.63× [0.58, 0.64] | 97% [97, 98] / 0.63× [0.58, 0.66] | -0.6% [-1.0%, -0.2%] | -2.2% [-2.5%, -2.0%] | -0.1% [-0.1%, -0.1%] |
| JsonParseSerializable | 1.677 s, 500 MiB | 96% [96, 97] / 0.89× [0.88, 0.90] | 98% [98, 99] / 0.83× [0.83, 0.84] | +1.2% [+0.9%, +1.7%] | -2.1% [-2.5%, -1.7%] | -6.0% [-7.0%, -5.3%] |
| JsonParsePull | 1.657 s, 502 MiB | 96% [95, 97] / 0.88× [0.87, 0.91] | 99% [98, 99] / 0.83× [0.82, 0.86] | +0.8% [+0.5%, +1.5%] | -2.5% [-3.3%, -2.1%] | -6.3% [-6.8%, -5.7%] |
| Revcomp | 3.094 s, 662 MiB | 99% [98, 99] / 0.79× [0.70, 0.84] | 99% [98, 99] / 0.79× [0.69, 0.84] | +0.7% [+0.0%, +1.3%] | +0.1% [-0.1%, +0.4%] | -0.1% [-0.1%, -0.1%] |
| RegexDna | 3.152 s, 393 MiB | 98% [98, 99] / 0.64× [0.50, 0.66] | 98% [98, 99] / 0.55× [0.42, 0.57] | -0.4% [-0.5%, -0.2%] | +0.0% [-0.2%, +0.4%] | -14.3% [-14.3%, -14.3%] |
| Knuckeotide | 1.194 s, 46 MiB | 88% [87, 89] / 1.32× [1.14, 1.43] | 88% [87, 89] / 1.18× [0.98, 1.39] | +0.5% [-0.2%, +1.0%] | +0.3% [-0.3%, +1.0%] | -9.7% [-17.0%, +8.4%] |

Kemal, 15 trials (req/s % of Boehm / peak × Boehm (gcry peak), medians of per-trial paired ratios [IQR]; last two columns 0.37 against 0.36.0, paired per trial):

| path | 0.36.0 req/s % / peak × Boehm | 0.37 req/s % / peak × Boehm | 0.37 vs 0.36.0 req/s | peak |
|---|---|---|---:|---:|
| `/json` | 104.0% [100.9, 107.3] / 1.48× [1.47, 1.49] (20.3 MiB) | 105.6% [102.8, 108.8] / 1.32× [1.31, 1.33] (18.1 MiB) | +1.1% [-0.1%, +4.8%] | -10.7% [-10.7%, -10.7%] |
| `/` | 98.9% [97.3, 100.3] / 1.45× [1.44, 1.45] (19.6 MiB) | 99.2% [97.6, 100.9] / 1.34× [1.34, 1.35] (18.2 MiB) | +1.2% [-1.0%, +2.6%] | -7.1% [-7.2%, -7.1%] |

### macOS arm64 `macos-latest`, run 1

Run 39056939449; raw `arm64-r1-summary.md`, `arm64-r1-runs.json`, `arm64-r1-kemal-*`, `arm64-r1-gc-counters.txt`.

| bench | Boehm | 0.36.0 speed / peak | 0.37 speed / peak | 0.37 vs 0.36.0: timed | wall | peak |
|---|---:|---|---|---:|---:|---:|
| Primes | 1.078 s, 696 MiB | 98% [95, 108] / 0.88× [0.87, 0.88] | 105% [95, 109] / 0.89× [0.89, 0.89] | -7.9% [-10.7%, -1.8%] | -7.7% [-10.5%, -1.9%] | +0.9% [+0.4%, +1.3%] |
| JsonParsePure | 1.290 s, 518 MiB | 93% [87, 98] / 1.08× [1.08, 1.11] | 96% [89, 102] / 1.08× [1.07, 1.10] | +1.1% [-8.4%, +8.1%] | -3.1% [-11.0%, +4.9%] | -0.2% [-0.7%, -0.0%] |
| Binarytrees | 0.809 s, 39 MiB | 80% [74, 82] / 1.78× [1.78, 1.78] | 88% [86, 91] / 0.94× [0.94, 0.94] | -10.6% [-12.0%, -8.3%] | -10.5% [-12.2%, -8.3%] | -47.4% [-47.4%, -47.4%] |
| JsonGenerate | 2.488 s, 1198 MiB | 99% [96, 111] / 0.64× [0.64, 0.64] | 105% [98, 113] / 0.73× [0.64, 0.77] | +2.1% [-3.2%, +7.8%] | -2.3% [-5.2%, +0.6%] | +20.3% [-0.0%, +20.4%] |
| JsonParseSerializable | 1.402 s, 521 MiB | 101% [98, 105] / 0.93× [0.90, 0.95] | 102% [100, 104] / 0.93× [0.91, 0.94] | -0.4% [-1.7%, +7.9%] | -1.3% [-2.9%, +2.8%] | -0.9% [-1.5%, -0.2%] |
| JsonParsePull | 1.379 s, 521 MiB | 99% [97, 105] / 0.94× [0.92, 0.95] | 100% [96, 102] / 0.92× [0.91, 0.94] | +1.9% [-3.2%, +6.2%] | -0.6% [-2.3%, +3.8%] | -1.0% [-1.7%, -0.4%] |
| Revcomp | 3.258 s, 830 MiB | 96% [93, 98] / 0.64× [0.63, 0.64] | 98% [94, 101] / 0.63× [0.63, 0.64] | -6.7% [-8.9%, +1.9%] | -0.5% [-6.5%, +3.3%] | -0.0% [-0.1%, -0.0%] |
| RegexDna | 3.536 s, 536 MiB | 96% [94, 101] / 0.51× [0.51, 0.51] | 97% [96, 100] / 0.50× [0.50, 0.51] | -2.3% [-4.7%, +1.4%] | -2.4% [-3.9%, +0.9%] | -0.5% [-0.5%, -0.5%] |
| Knuckeotide | 1.110 s, 47 MiB | 85% [79, 91] / 1.88× [1.88, 2.25] | 92% [87, 98] / 1.56× [1.56, 1.85] | -5.5% [-10.5%, -3.9%] | -5.7% [-9.8%, -3.8%] | -17.1% [-17.1%, -17.1%] |

Kemal, 15 trials (req/s % of Boehm / peak × Boehm (gcry peak), medians of per-trial paired ratios [IQR]; last two columns 0.37 against 0.36.0, paired per trial):

| path | 0.36.0 req/s % / peak × Boehm | 0.37 req/s % / peak × Boehm | 0.37 vs 0.36.0 req/s | peak |
|---|---|---|---:|---:|
| `/json` | 104.5% [95.1, 108.4] / 1.95× [1.92, 2.00] (29.2 MiB) | 107.1% [98.9, 111.3] / 1.38× [1.36, 1.40] (20.2 MiB) | +6.8% [-1.2%, +12.4%] | -29.8% [-31.1%, -27.7%] |
| `/` | 99.4% [90.3, 105.3] / 1.90× [1.90, 1.91] (28.7 MiB) | 103.0% [94.0, 113.6] / 1.35× [1.32, 1.36] (20.3 MiB) | +2.4% [-2.0%, +11.8%] | -29.2% [-30.3%, -29.0%] |

### macOS arm64 `macos-latest`, run 2

Run 39061365549; raw `arm64-r2-summary.md`, `arm64-r2-runs.json`, `arm64-r2-kemal-*`, `arm64-r2-gc-counters.txt`.

| bench | Boehm | 0.36.0 speed / peak | 0.37 speed / peak | 0.37 vs 0.36.0: timed | wall | peak |
|---|---:|---|---|---:|---:|---:|
| Primes | 0.885 s, 696 MiB | 99% [91, 100] / 0.88× [0.88, 0.88] | 105% [103, 107] / 0.89× [0.89, 0.89] | -6.9% [-12.2%, -5.5%] | -6.8% [-12.3%, -5.4%] | +1.1% [+1.1%, +1.2%] |
| JsonParsePure | 1.150 s, 518 MiB | 93% [91, 97] / 1.08× [1.08, 1.08] | 99% [95, 101] / 1.07× [1.07, 1.07] | -4.4% [-6.8%, -3.3%] | -4.7% [-5.8%, -3.4%] | -0.7% [-0.9%, -0.3%] |
| Binarytrees | 0.720 s, 39 MiB | 78% [76, 79] / 1.78× [1.78, 1.78] | 87% [86, 89] / 0.94× [0.94, 0.94] | -11.3% [-12.7%, -10.2%] | -11.2% [-12.6%, -10.2%] | -47.4% [-47.4%, -47.4%] |
| JsonGenerate | 2.118 s, 1198 MiB | 99% [96, 103] / 0.64× [0.64, 0.72] | 101% [98, 104] / 0.64× [0.64, 0.77] | +0.4% [-0.6%, +5.0%] | -3.0% [-4.0%, +4.3%] | -0.0% [-1.8%, +5.0%] |
| JsonParseSerializable | 1.215 s, 498 MiB | 99% [98, 103] / 0.98× [0.95, 0.99] | 100% [98, 101] / 0.96× [0.93, 0.97] | +0.2% [-1.3%, +0.7%] | -0.8% [-1.4%, +1.4%] | -1.8% [-2.4%, -1.7%] |
| JsonParsePull | 1.215 s, 521 MiB | 99% [99, 102] / 0.95× [0.94, 0.97] | 100% [98, 103] / 0.94× [0.92, 0.96] | +1.0% [+0.0%, +3.2%] | -1.2% [-1.7%, +1.8%] | -1.2% [-1.8%, -1.1%] |
| Revcomp | 2.963 s, 830 MiB | 98% [97, 100] / 0.63× [0.56, 0.64] | 100% [96, 102] / 0.63× [0.56, 0.64] | -0.7% [-3.9%, +2.7%] | -0.3% [-2.4%, +3.0%] | -0.0% [-0.0%, -0.0%] |
| RegexDna | 3.236 s, 536 MiB | 99% [98, 101] / 0.51× [0.51, 0.51] | 98% [95, 101] / 0.50× [0.50, 0.51] | -1.3% [-1.5%, +3.3%] | +1.3% [-1.2%, +3.0%] | -0.5% [-0.5%, -0.5%] |
| Knuckeotide | 0.953 s, 47 MiB | 89% [87, 94] / 1.88× [1.88, 2.19] | 92% [89, 97] / 1.56× [1.56, 1.80] | -2.2% [-3.6%, +2.8%] | -2.0% [-3.3%, +3.0%] | -17.1% [-17.1%, -17.1%] |

Kemal, 15 trials (req/s % of Boehm / peak × Boehm (gcry peak), medians of per-trial paired ratios [IQR]; last two columns 0.37 against 0.36.0, paired per trial):

| path | 0.36.0 req/s % / peak × Boehm | 0.37 req/s % / peak × Boehm | 0.37 vs 0.36.0 req/s | peak |
|---|---|---|---:|---:|
| `/json` | 102.3% [101.6, 113.3] / 1.98× [1.95, 2.02] (29.2 MiB) | 103.5% [93.7, 115.4] / 1.39× [1.38, 1.44] (20.8 MiB) | +0.7% [-7.9%, +2.3%] | -28.9% [-29.9%, -28.7%] |
| `/` | 101.1% [98.5, 101.6] / 1.91× [1.89, 1.92] (28.8 MiB) | 99.1% [98.7, 105.6] / 1.33× [1.33, 1.36] (20.0 MiB) | -0.0% [-1.8%, +5.5%] | -29.6% [-30.2%, -29.0%] |

### macOS x86_64 `macos-15-intel`

Run 39056939449; raw `intel-summary.md`, `intel-runs.json`, `intel-kemal-*`, `intel-gc-counters.txt`.

| bench | Boehm | 0.36.0 speed / peak | 0.37 speed / peak | 0.37 vs 0.36.0: timed | wall | peak |
|---|---:|---|---|---:|---:|---:|
| Primes | 2.137 s, 667 MiB | 92% [89, 97] / 0.91× [0.84, 0.91] | 105% [97, 106] / 0.92× [0.87, 0.92] | -11.6% [-13.0%, -9.7%] | -10.9% [-12.9%, -9.4%] | +1.6% [+1.3%, +1.8%] |
| JsonParsePure | 2.966 s, 683 MiB | 91% [88, 95] / 0.82× [0.81, 0.82] | 97% [93, 100] / 0.83× [0.82, 0.83] | -4.1% [-9.4%, -0.9%] | -3.7% [-6.8%, +0.9%] | +1.1% [+0.3%, +1.5%] |
| Binarytrees | 2.278 s, 36 MiB | 90% [87, 91] / 1.87× [1.87, 1.87] | 127% [123, 131] / 0.96× [0.96, 0.96] | -29.4% [-32.7%, -26.6%] | -29.2% [-32.5%, -26.5%] | -48.6% [-48.6%, -48.6%] |
| JsonGenerate | 4.997 s, 1194 MiB | 96% [90, 102] / 0.65× [0.61, 0.65] | 99% [96, 102] / 0.65× [0.61, 0.65] | -4.4% [-10.0%, +1.2%] | -5.6% [-9.4%, +0.7%] | -0.0% [-0.0%, +0.0%] |
| JsonParseSerializable | 3.461 s, 547 MiB | 96% [93, 99] / 0.84× [0.83, 0.85] | 100% [97, 103] / 0.84× [0.83, 0.85] | -2.2% [-6.3%, +2.8%] | -1.1% [-6.7%, +3.2%] | -0.1% [-0.7%, +0.4%] |
| JsonParsePull | 3.335 s, 512 MiB | 96% [92, 100] / 0.90× [0.88, 0.92] | 103% [99, 104] / 0.90× [0.89, 0.90] | -3.2% [-5.5%, +0.3%] | -7.0% [-8.4%, -3.5%] | -0.6% [-2.4%, +0.7%] |
| Revcomp | 4.892 s, 978 MiB | 92% [91, 95] / 0.62× [0.57, 0.67] | 92% [89, 94] / 0.56× [0.55, 0.64] | +3.5% [-1.4%, +7.5%] | +2.1% [-1.3%, +6.3%] | -6.7% [-17.5%, +3.8%] |
| RegexDna | 4.722 s, 594 MiB | 99% [95, 101] / 0.50× [0.45, 0.54] | 99% [97, 102] / 0.50× [0.50, 0.55] | -1.9% [-4.8%, -0.1%] | -0.5% [-3.5%, +2.2%] | -0.5% [-6.2%, +10.7%] |
| Knuckeotide | 2.465 s, 45 MiB | 88% [81, 91] / 2.04× [1.93, 2.06] | 101% [97, 104] / 1.64× [1.56, 1.80] | -12.1% [-16.1%, -9.9%] | -11.5% [-15.5%, -9.5%] | -14.6% [-22.4%, -11.6%] |

Kemal, 15 trials (req/s % of Boehm / peak × Boehm (gcry peak), medians of per-trial paired ratios [IQR]; last two columns 0.37 against 0.36.0, paired per trial):

| path | 0.36.0 req/s % / peak × Boehm | 0.37 req/s % / peak × Boehm | 0.37 vs 0.36.0 req/s | peak |
|---|---|---|---:|---:|
| `/json` | 106.6% [94.3, 121.8] / 2.20× [2.19, 2.21] (23.0 MiB) | 107.2% [99.9, 116.6] / 1.39× [1.38, 1.40] (14.5 MiB) | -0.8% [-15.1%, +11.1%] | -36.8% [-37.2%, -36.5%] |
| `/` | 100.3% [97.8, 110.0] / 2.22× [2.22, 2.22] (23.0 MiB) | 108.1% [99.2, 118.7] / 1.41× [1.40, 1.41] (14.6 MiB) | +8.7% [-1.0%, +17.0%] | -36.6% [-36.8%, -36.3%] |

### Windows x86_64 `windows-latest`

Run 39056939449; raw `x86-summary.md`, `x86-runs.json`, `x86-gc-counters.txt`.

| bench | Boehm | 0.36.0 speed / peak | 0.37 speed / peak | 0.37 vs 0.36.0: timed | wall | peak |
|---|---:|---|---|---:|---:|---:|
| Primes | 1.417 s, 665 MiB | 102% [98, 105] / 0.92× [0.92, 0.92] | 107% [102, 109] / 0.93× [0.93, 0.93] | -3.5% [-6.7%, +2.5%] | -5.5% [-6.8%, -2.8%] | +1.0% [+0.9%, +1.1%] |
| JsonParsePure | 1.657 s, 518 MiB | 103% [101, 105] / 1.08× [1.08, 1.08] | 103% [100, 107] / 1.08× [1.07, 1.08] | -1.8% [-3.5%, -0.2%] | -0.7% [-2.5%, +2.3%] | -0.6% [-0.7%, -0.3%] |
| Binarytrees | 1.225 s, 44 MiB | 108% [104, 111] / 0.94× [0.94, 0.94] | 108% [101, 113] / 0.92× [0.92, 0.92] | +0.4% [-2.8%, +2.1%] | -0.4% [-5.2%, +8.3%] | -2.2% [-2.2%, -2.1%] |
| JsonGenerate | 2.641 s, 1335 MiB | 99% [98, 101] / 0.58× [0.58, 0.58] | 99% [98, 101] / 0.58× [0.58, 0.58] | -0.4% [-1.7%, +1.1%] | -0.3% [-1.4%, +2.5%] | -0.0% [-0.1%, +0.0%] |
| JsonParseSerializable | 1.542 s, 555 MiB | 99% [95, 101] / 0.81× [0.80, 0.82] | 99% [94, 102] / 0.82× [0.81, 0.85] | -1.1% [-2.4%, +0.5%] | +0.7% [-2.7%, +5.3%] | +0.5% [-2.5%, +6.9%] |
| JsonParsePull | 1.559 s, 555 MiB | 101% [96, 106] / 0.79× [0.79, 0.81] | 101% [96, 105] / 0.81× [0.81, 0.82] | -1.4% [-2.1%, -0.9%] | -0.7% [-3.0%, +2.6%] | +2.2% [+0.1%, +3.6%] |
| Revcomp | 3.252 s, 897 MiB | 95% [93, 96] / 0.61× [0.57, 0.62] | 98% [96, 98] / 0.61× [0.57, 0.61] | -3.4% [-4.9%, -2.0%] | -2.8% [-4.9%, -2.0%] | -0.1% [-0.1%, -0.1%] |
| RegexDna | 3.837 s, 527 MiB | 99% [97, 100] / 0.50× [0.50, 0.50] | 99% [99, 99] / 0.47× [0.47, 0.47] | +0.0% [-0.2%, +0.2%] | -0.3% [-1.3%, +1.1%] | -6.9% [-6.9%, -6.9%] |
| Knuckeotide | 1.268 s, 52 MiB | 94% [89, 97] / 1.67× [1.64, 1.67] | 94% [89, 94] / 1.73× [1.64, 1.91] | +2.2% [-0.5%, +3.8%] | +0.4% [-1.8%, +6.6%] | +4.9% [-0.8%, +17.5%] |
