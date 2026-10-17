Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 72969 | 100.0% [100.0, 100.0] | 14.9 MiB | 1.00× [1.00, 1.00] |
| base | 75715 | 105.9% [102.5, 110.1] | 29.2 MiB | 1.94× [1.92, 1.96] |
| var | 73565 | 102.3% [92.1, 107.0] | 29.3 MiB | 1.95× [1.93, 1.96] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 112006 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 114094 | 103.4% [100.8, 107.1] | 28.9 MiB | 1.91× [1.91, 1.92] |
| var | 115200 | 105.8% [100.4, 108.8] | 28.8 MiB | 1.91× [1.89, 1.92] |

