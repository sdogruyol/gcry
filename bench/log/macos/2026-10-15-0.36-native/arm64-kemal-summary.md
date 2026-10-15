Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 84036 | 100.0% [100.0, 100.0] | 15.0 MiB | 1.00× [1.00, 1.00] |
| base | 86069 | 102.8% [100.1, 103.5] | 29.5 MiB | 1.97× [1.95, 1.97] |
| var | 85899 | 102.1% [101.3, 102.9] | 29.2 MiB | 1.94× [1.93, 1.96] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 130739 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 130307 | 99.6% [98.0, 100.8] | 29.2 MiB | 1.93× [1.93, 1.94] |
| var | 131139 | 100.3% [99.7, 101.9] | 28.9 MiB | 1.91× [1.91, 1.92] |

