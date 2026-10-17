Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 36941 | 100.0% [100.0, 100.0] | 15.3 MiB | 1.00× [1.00, 1.00] |
| base | 41033 | 110.8% [106.9, 113.1] | 20.9 MiB | 1.37× [1.17, 1.40] |
| var | 38456 | 104.9% [100.5, 105.5] | 18.7 MiB | 1.22× [1.05, 1.24] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 64452 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 67603 | 104.8% [100.8, 108.1] | 20.3 MiB | 1.36× [1.19, 1.41] |
| var | 66077 | 102.8% [100.9, 105.4] | 18.7 MiB | 1.24× [1.11, 1.30] |

