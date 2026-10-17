Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 55295 | 100.0% [100.0, 100.0] | 14.9 MiB | 1.00× [1.00, 1.00] |
| base | 56260 | 104.5% [95.1, 108.4] | 29.2 MiB | 1.95× [1.92, 2.00] |
| var | 57624 | 107.1% [98.9, 111.3] | 20.2 MiB | 1.38× [1.36, 1.40] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 74150 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 73695 | 99.4% [90.3, 105.3] | 28.7 MiB | 1.90× [1.90, 1.91] |
| var | 77567 | 103.0% [94.0, 113.6] | 20.3 MiB | 1.35× [1.32, 1.36] |

