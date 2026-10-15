Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 0.5 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 20653 | 100.0% [100.0, 100.0] | 10.4 MiB | 1.00× [1.00, 1.00] |
| base | 22314 | 101.4% [96.8, 107.9] | 23.1 MiB | 2.21× [2.20, 2.22] |
| var | 22369 | 111.9% [96.4, 117.2] | 23.0 MiB | 2.20× [2.19, 2.22] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 38457 | 100.0% [100.0, 100.0] | 10.3 MiB | 1.00× [1.00, 1.00] |
| base | 40876 | 110.0% [94.2, 118.7] | 23.1 MiB | 2.24× [2.23, 2.24] |
| var | 39133 | 106.0% [92.9, 114.5] | 22.9 MiB | 2.22× [2.21, 2.22] |

