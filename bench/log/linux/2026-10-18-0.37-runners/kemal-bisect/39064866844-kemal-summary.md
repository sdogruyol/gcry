Kemal, 20 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 37509 | 100.0% [100.0, 100.0] | 15.7 MiB | 1.00× [1.00, 1.00] |
| base | 38791 | 104.6% [98.1, 106.4] | 18.7 MiB | 1.19× [1.04, 1.27] |
| var | 38354 | 102.2% [100.5, 106.0] | 18.7 MiB | 1.20× [1.04, 1.27] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 64150 | 100.0% [100.0, 100.0] | 15.4 MiB | 1.00× [1.00, 1.00] |
| base | 64823 | 101.2% [97.7, 104.3] | 18.7 MiB | 1.22× [1.06, 1.27] |
| var | 63761 | 100.5% [97.1, 102.7] | 18.7 MiB | 1.21× [1.05, 1.27] |

