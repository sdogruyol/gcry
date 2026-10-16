Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 0.5 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 17950 | 100.0% [100.0, 100.0] | 10.5 MiB | 1.00× [1.00, 1.00] |
| base | 18800 | 109.8% [98.2, 125.5] | 23.0 MiB | 2.19× [2.18, 2.19] |
| var | 19679 | 109.3% [96.9, 122.3] | 16.4 MiB | 1.56× [1.55, 1.58] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 30054 | 100.0% [100.0, 100.0] | 10.4 MiB | 1.00× [1.00, 1.00] |
| base | 31341 | 106.1% [94.8, 108.7] | 23.0 MiB | 2.21× [2.20, 2.22] |
| var | 32317 | 104.0% [98.6, 111.3] | 16.4 MiB | 1.57× [1.57, 1.58] |

