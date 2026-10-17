Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 56657 | 100.0% [100.0, 100.0] | 13.7 MiB | 1.00× [1.00, 1.00] |
| base | 59140 | 104.0% [100.9, 107.3] | 20.3 MiB | 1.48× [1.47, 1.49] |
| var | 59601 | 105.6% [102.8, 108.8] | 18.1 MiB | 1.32× [1.31, 1.33] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 107912 | 100.0% [100.0, 100.0] | 13.5 MiB | 1.00× [1.00, 1.00] |
| base | 106581 | 98.9% [97.3, 100.3] | 19.6 MiB | 1.45× [1.44, 1.45] |
| var | 107172 | 99.2% [97.6, 100.9] | 18.2 MiB | 1.34× [1.34, 1.35] |

