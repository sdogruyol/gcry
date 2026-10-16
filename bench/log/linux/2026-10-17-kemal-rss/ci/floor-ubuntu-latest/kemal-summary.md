Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 67657 | 100.0% [100.0, 100.0] | 16.4 MiB | 1.00× [1.00, 1.00] |
| base | 70720 | 104.3% [100.2, 106.6] | 21.1 MiB | 1.28× [1.16, 1.40] |
| var | 72813 | 105.3% [103.7, 109.2] | 17.7 MiB | 1.05× [0.98, 1.13] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 95975 | 100.0% [100.0, 100.0] | 15.0 MiB | 1.00× [1.00, 1.00] |
| base | 95780 | 98.8% [97.8, 100.5] | 20.4 MiB | 1.36× [1.15, 1.41] |
| var | 96056 | 99.9% [98.8, 101.1] | 14.9 MiB | 0.99× [0.83, 1.02] |

