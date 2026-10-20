Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 36940 | 100.0% [100.0, 100.0] | 18.7 MiB | 1.00× [1.00, 1.00] |
| base | 39869 | 108.2% [99.6, 112.4] | 18.7 MiB | 1.00× [0.99, 1.02] |
| var | 39766 | 107.2% [103.4, 109.7] | 18.8 MiB | 1.00× [0.99, 1.04] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 63872 | 100.0% [100.0, 100.0] | 17.7 MiB | 1.00× [1.00, 1.00] |
| base | 66873 | 103.9% [99.6, 106.8] | 18.7 MiB | 1.07× [1.06, 1.15] |
| var | 66779 | 104.2% [100.4, 106.5] | 18.7 MiB | 1.06× [1.06, 1.11] |

