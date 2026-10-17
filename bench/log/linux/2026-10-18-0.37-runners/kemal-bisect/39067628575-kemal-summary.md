Kemal, 25 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 36590 | 100.0% [100.0, 100.0] | 17.8 MiB | 1.00× [1.00, 1.00] |
| base | 39602 | 107.4% [104.2, 109.7] | 21.0 MiB | 1.18× [1.11, 1.29] |
| var | 39862 | 107.2% [104.9, 109.9] | 19.2 MiB | 1.08× [1.05, 1.26] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 64037 | 100.0% [100.0, 100.0] | 17.3 MiB | 1.00× [1.00, 1.00] |
| base | 65618 | 102.3% [100.4, 104.7] | 20.3 MiB | 1.24× [1.14, 1.34] |
| var | 65595 | 102.2% [99.5, 107.1] | 19.2 MiB | 1.17× [1.08, 1.27] |

