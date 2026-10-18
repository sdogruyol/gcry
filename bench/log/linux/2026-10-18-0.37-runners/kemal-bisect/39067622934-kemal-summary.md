Kemal, 25 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 54999 | 100.0% [100.0, 100.0] | 18.0 MiB | 1.00× [1.00, 1.00] |
| base | 59856 | 109.4% [107.4, 109.9] | 19.4 MiB | 1.15× [1.07, 1.27] |
| var | 58066 | 106.1% [104.2, 107.0] | 18.9 MiB | 1.06× [1.01, 1.24] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 84389 | 100.0% [100.0, 100.0] | 17.4 MiB | 1.00× [1.00, 1.00] |
| base | 85838 | 102.0% [99.9, 103.4] | 19.3 MiB | 1.15× [1.07, 1.32] |
| var | 85283 | 100.5% [99.3, 102.8] | 18.8 MiB | 1.14× [1.05, 1.29] |

