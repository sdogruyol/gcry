Kemal, 20 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 53115 | 100.0% [100.0, 100.0] | 16.0 MiB | 1.00× [1.00, 1.00] |
| base | 58315 | 109.2% [107.3, 112.4] | 19.4 MiB | 1.22× [1.07, 1.32] |
| var | 57198 | 108.6% [105.7, 109.6] | 18.9 MiB | 1.18× [1.05, 1.29] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 81017 | 100.0% [100.0, 100.0] | 15.7 MiB | 1.00× [1.00, 1.00] |
| base | 81626 | 100.4% [99.2, 102.8] | 19.4 MiB | 1.23× [1.08, 1.33] |
| var | 81813 | 100.5% [99.3, 101.5] | 18.8 MiB | 1.20× [1.05, 1.30] |

