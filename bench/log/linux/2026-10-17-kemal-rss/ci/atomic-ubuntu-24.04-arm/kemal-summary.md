Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 58327 | 100.0% [100.0, 100.0] | 17.1 MiB | 1.00× [1.00, 1.00] |
| base | 60082 | 104.5% [102.2, 105.3] | 20.3 MiB | 1.19× [1.18, 1.49] |
| var | 61663 | 105.0% [104.1, 107.9] | 18.5 MiB | 1.08× [1.08, 1.36] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 109568 | 100.0% [100.0, 100.0] | 13.6 MiB | 1.00× [1.00, 1.00] |
| base | 109163 | 99.5% [97.9, 100.8] | 19.7 MiB | 1.45× [1.45, 1.45] |
| var | 109494 | 100.6% [99.2, 101.6] | 18.7 MiB | 1.38× [1.37, 1.38] |

