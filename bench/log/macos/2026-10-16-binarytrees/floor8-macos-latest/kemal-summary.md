Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 52042 | 100.0% [100.0, 100.0] | 14.9 MiB | 1.00× [1.00, 1.00] |
| base | 50891 | 105.2% [92.7, 111.1] | 28.6 MiB | 1.93× [1.91, 1.95] |
| var | 55427 | 116.9% [98.3, 119.4] | 25.1 MiB | 1.69× [1.68, 1.70] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 75263 | 100.0% [100.0, 100.0] | 15.0 MiB | 1.00× [1.00, 1.00] |
| base | 63174 | 99.0% [90.2, 107.4] | 28.6 MiB | 1.91× [1.90, 1.91] |
| var | 67126 | 97.6% [91.7, 108.1] | 24.9 MiB | 1.66× [1.65, 1.68] |

