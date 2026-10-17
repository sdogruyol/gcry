Kemal, 25 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 37492 | 100.0% [100.0, 100.0] | 17.6 MiB | 1.00× [1.00, 1.00] |
| base | 40549 | 109.2% [106.7, 110.3] | 19.2 MiB | 1.16× [1.07, 1.24] |
| var | 39255 | 104.8% [103.3, 109.4] | 18.7 MiB | 1.06× [1.04, 1.22] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 64074 | 100.0% [100.0, 100.0] | 17.6 MiB | 1.00× [1.00, 1.00] |
| base | 66768 | 104.8% [100.6, 107.5] | 19.2 MiB | 1.13× [1.07, 1.28] |
| var | 65936 | 100.9% [99.3, 105.7] | 18.7 MiB | 1.07× [1.04, 1.25] |

