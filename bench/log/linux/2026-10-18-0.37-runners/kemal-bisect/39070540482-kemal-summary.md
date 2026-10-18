Kemal, 25 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 65756 | 100.0% [100.0, 100.0] | 15.3 MiB | 1.00× [1.00, 1.00] |
| base | 70895 | 107.5% [106.0, 111.4] | 18.9 MiB | 1.24× [1.05, 1.29] |
| var | 71583 | 110.7% [106.0, 114.7] | 19.3 MiB | 1.27× [1.08, 1.33] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 117345 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 119687 | 102.2% [99.9, 104.3] | 18.9 MiB | 1.25× [1.16, 1.26] |
| var | 119259 | 101.8% [99.3, 102.9] | 19.3 MiB | 1.29× [1.10, 1.29] |

