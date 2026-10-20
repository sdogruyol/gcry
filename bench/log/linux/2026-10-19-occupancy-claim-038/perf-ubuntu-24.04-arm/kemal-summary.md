Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 61037 | 100.0% [100.0, 100.0] | 13.8 MiB | 1.00× [1.00, 1.00] |
| base | 61549 | 101.2% [100.6, 103.4] | 18.1 MiB | 1.31× [1.06, 1.33] |
| var | 61333 | 101.9% [98.5, 105.8] | 18.0 MiB | 1.31× [1.05, 1.33] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 111397 | 100.0% [100.0, 100.0] | 13.6 MiB | 1.00× [1.00, 1.00] |
| base | 111195 | 99.8% [97.4, 102.2] | 18.2 MiB | 1.34× [1.34, 1.34] |
| var | 111333 | 99.9% [98.4, 101.1] | 18.2 MiB | 1.34× [1.33, 1.34] |

