Kemal, 25 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 36814 | 100.0% [100.0, 100.0] | 18.0 MiB | 1.00× [1.00, 1.00] |
| base | 38271 | 104.1% [102.0, 107.9] | 18.7 MiB | 1.04× [0.99, 1.05] |
| var | 38455 | 105.6% [101.1, 109.5] | 19.2 MiB | 1.07× [1.02, 1.08] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 64143 | 100.0% [100.0, 100.0] | 17.7 MiB | 1.00× [1.00, 1.00] |
| base | 65045 | 102.0% [97.3, 106.5] | 18.7 MiB | 1.06× [1.03, 1.15] |
| var | 65862 | 102.8% [99.4, 105.5] | 19.2 MiB | 1.09× [1.06, 1.19] |

