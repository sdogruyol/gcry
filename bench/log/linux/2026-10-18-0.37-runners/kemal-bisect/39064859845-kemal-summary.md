Kemal, 20 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 37073 | 100.0% [100.0, 100.0] | 17.8 MiB | 1.00× [1.00, 1.00] |
| base | 39831 | 107.6% [103.2, 109.9] | 21.0 MiB | 1.18× [1.17, 1.37] |
| var | 39395 | 106.7% [102.5, 111.0] | 20.9 MiB | 1.18× [1.17, 1.36] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 63817 | 100.0% [100.0, 100.0] | 17.7 MiB | 1.00× [1.00, 1.00] |
| base | 64801 | 102.0% [97.9, 107.9] | 20.3 MiB | 1.24× [1.13, 1.34] |
| var | 64469 | 100.5% [98.6, 107.1] | 20.3 MiB | 1.15× [1.13, 1.34] |

