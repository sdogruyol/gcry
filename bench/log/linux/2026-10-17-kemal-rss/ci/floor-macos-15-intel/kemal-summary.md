Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 0.5 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 18932 | 100.0% [100.0, 100.0] | 10.5 MiB | 1.00× [1.00, 1.00] |
| base | 20735 | 113.0% [108.1, 117.2] | 16.4 MiB | 1.57× [1.56, 1.57] |
| var | 19988 | 110.1% [103.7, 117.0] | 15.0 MiB | 1.43× [1.42, 1.44] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 34072 | 100.0% [100.0, 100.0] | 10.4 MiB | 1.00× [1.00, 1.00] |
| base | 33981 | 106.8% [98.8, 112.7] | 16.4 MiB | 1.58× [1.57, 1.58] |
| var | 33553 | 103.6% [93.4, 120.2] | 10.9 MiB | 1.05× [1.04, 1.12] |

