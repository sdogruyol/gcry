Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 0.5 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 20182 | 100.0% [100.0, 100.0] | 10.4 MiB | 1.00× [1.00, 1.00] |
| base | 21939 | 106.6% [94.3, 121.8] | 23.0 MiB | 2.20× [2.19, 2.21] |
| var | 21697 | 107.2% [99.9, 116.6] | 14.5 MiB | 1.39× [1.38, 1.40] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 36660 | 100.0% [100.0, 100.0] | 10.4 MiB | 1.00× [1.00, 1.00] |
| base | 39998 | 100.3% [97.8, 110.0] | 23.0 MiB | 2.22× [2.22, 2.22] |
| var | 42438 | 108.1% [99.2, 118.7] | 14.6 MiB | 1.41× [1.40, 1.41] |

