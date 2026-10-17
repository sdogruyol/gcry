Kemal, 25 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 36730 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 38143 | 102.7% [99.0, 110.9] | 18.7 MiB | 1.24× [1.16, 1.29] |
| var | 39162 | 106.7% [101.8, 110.7] | 19.2 MiB | 1.27× [1.16, 1.33] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 63246 | 100.0% [100.0, 100.0] | 15.0 MiB | 1.00× [1.00, 1.00] |
| base | 64270 | 101.3% [99.9, 104.2] | 18.7 MiB | 1.25× [1.07, 1.30] |
| var | 65501 | 104.2% [100.7, 106.8] | 19.2 MiB | 1.28× [1.15, 1.33] |

