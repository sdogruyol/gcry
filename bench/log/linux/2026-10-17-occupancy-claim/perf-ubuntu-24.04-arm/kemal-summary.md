Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 56198 | 100.0% [100.0, 100.0] | 13.6 MiB | 1.00× [1.00, 1.00] |
| base | 58915 | 105.5% [102.0, 107.1] | 20.3 MiB | 1.49× [1.19, 1.50] |
| var | 60167 | 107.1% [104.0, 109.7] | 20.3 MiB | 1.49× [1.19, 1.50] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 107712 | 100.0% [100.0, 100.0] | 13.6 MiB | 1.00× [1.00, 1.00] |
| base | 105918 | 98.6% [97.2, 100.8] | 19.7 MiB | 1.45× [1.44, 1.45] |
| var | 107569 | 101.9% [98.8, 104.0] | 19.7 MiB | 1.45× [1.45, 1.45] |

