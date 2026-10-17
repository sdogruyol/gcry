Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 55384 | 100.0% [100.0, 100.0] | 15.0 MiB | 1.00× [1.00, 1.00] |
| base | 60987 | 105.9% [97.8, 114.4] | 25.1 MiB | 1.67× [1.66, 1.68] |
| var | 56726 | 96.3% [88.9, 106.2] | 20.9 MiB | 1.40× [1.37, 1.42] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 73485 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 79700 | 100.6% [95.8, 113.6] | 24.9 MiB | 1.65× [1.65, 1.67] |
| var | 78172 | 102.5% [92.1, 113.0] | 17.1 MiB | 1.13× [1.11, 1.19] |

