Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 36051 | 100.0% [100.0, 100.0] | 17.8 MiB | 1.00× [1.00, 1.00] |
| base | 38964 | 107.2% [104.1, 109.2] | 21.0 MiB | 1.18× [1.17, 1.28] |
| var | 39267 | 108.1% [103.3, 111.2] | 21.0 MiB | 1.17× [1.17, 1.27] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 62571 | 100.0% [100.0, 100.0] | 17.7 MiB | 1.00× [1.00, 1.00] |
| base | 65885 | 104.9% [102.0, 106.1] | 20.3 MiB | 1.14× [1.11, 1.22] |
| var | 65474 | 103.1% [100.6, 107.5] | 20.3 MiB | 1.14× [1.11, 1.16] |

