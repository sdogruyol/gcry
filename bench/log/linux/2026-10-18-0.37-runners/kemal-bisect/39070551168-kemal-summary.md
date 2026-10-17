Kemal, 25 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 52933 | 100.0% [100.0, 100.0] | 17.6 MiB | 1.00× [1.00, 1.00] |
| base | 54533 | 103.0% [99.8, 105.9] | 18.9 MiB | 1.16× [1.06, 1.24] |
| var | 55599 | 105.3% [103.7, 108.8] | 19.3 MiB | 1.17× [1.07, 1.27] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 99920 | 100.0% [100.0, 100.0] | 17.8 MiB | 1.00× [1.00, 1.00] |
| base | 102989 | 102.7% [99.8, 105.0] | 18.9 MiB | 1.06× [1.03, 1.26] |
| var | 103658 | 105.0% [101.8, 107.1] | 19.3 MiB | 1.09× [1.05, 1.29] |

