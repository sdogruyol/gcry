Kemal, 20 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 68510 | 100.0% [100.0, 100.0] | 18.1 MiB | 1.00× [1.00, 1.00] |
| base | 70950 | 103.5% [101.3, 105.4] | 21.1 MiB | 1.16× [1.12, 1.38] |
| var | 71482 | 105.1% [102.4, 106.6] | 19.3 MiB | 1.07× [1.03, 1.27] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 95111 | 100.0% [100.0, 100.0] | 17.8 MiB | 1.00× [1.00, 1.00] |
| base | 94963 | 99.6% [98.2, 100.7] | 20.4 MiB | 1.15× [1.12, 1.35] |
| var | 95386 | 99.5% [98.3, 101.3] | 19.3 MiB | 1.08× [1.04, 1.28] |

