Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 0.5 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 27964 | 100.0% [100.0, 100.0] | 10.5 MiB | 1.00× [1.00, 1.00] |
| base | 30805 | 110.1% [107.6, 114.5] | 23.0 MiB | 2.20× [2.19, 2.21] |
| var | 31190 | 112.4% [109.2, 115.1] | 16.4 MiB | 1.57× [1.56, 1.58] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 52237 | 100.0% [100.0, 100.0] | 10.3 MiB | 1.00× [1.00, 1.00] |
| base | 54208 | 105.4% [100.4, 108.5] | 23.0 MiB | 2.21× [2.21, 2.23] |
| var | 53885 | 103.8% [99.7, 106.7] | 16.4 MiB | 1.58× [1.58, 1.58] |

