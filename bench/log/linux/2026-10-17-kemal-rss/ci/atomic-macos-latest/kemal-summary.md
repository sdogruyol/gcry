Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 77270 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 80775 | 105.1% [103.9, 107.7] | 25.1 MiB | 1.67× [1.65, 1.69] |
| var | 80860 | 105.7% [104.1, 107.1] | 20.6 MiB | 1.37× [1.36, 1.40] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 121772 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 125294 | 101.9% [100.5, 104.5] | 25.0 MiB | 1.65× [1.64, 1.67] |
| var | 123948 | 101.6% [98.9, 103.5] | 21.0 MiB | 1.39× [1.37, 1.39] |

