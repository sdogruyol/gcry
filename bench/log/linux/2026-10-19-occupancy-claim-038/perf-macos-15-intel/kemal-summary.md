Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 0.5 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 19242 | 100.0% [100.0, 100.0] | 10.4 MiB | 1.00× [1.00, 1.00] |
| base | 20830 | 111.9% [102.0, 116.2] | 14.4 MiB | 1.39× [1.38, 1.39] |
| var | 24199 | 116.4% [109.6, 120.5] | 14.5 MiB | 1.39× [1.38, 1.40] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 31659 | 100.0% [100.0, 100.0] | 10.4 MiB | 1.00× [1.00, 1.00] |
| base | 33457 | 103.9% [98.5, 107.1] | 14.5 MiB | 1.40× [1.40, 1.41] |
| var | 36631 | 103.6% [99.4, 107.8] | 14.6 MiB | 1.41× [1.40, 1.41] |

