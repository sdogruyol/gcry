Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 55003 | 100.0% [100.0, 100.0] | 15.0 MiB | 1.00× [1.00, 1.00] |
| base | 56428 | 105.5% [93.4, 112.0] | 29.1 MiB | 1.94× [1.92, 1.95] |
| var | 60655 | 107.2% [94.3, 119.3] | 25.5 MiB | 1.69× [1.67, 1.70] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 69493 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 78472 | 107.2% [101.3, 112.0] | 28.8 MiB | 1.90× [1.89, 1.91] |
| var | 69000 | 102.9% [92.9, 112.2] | 24.8 MiB | 1.65× [1.64, 1.66] |

