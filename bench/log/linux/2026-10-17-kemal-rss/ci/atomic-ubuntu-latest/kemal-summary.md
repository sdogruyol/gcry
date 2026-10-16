Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 58419 | 100.0% [100.0, 100.0] | 15.2 MiB | 1.00× [1.00, 1.00] |
| base | 59365 | 102.9% [100.1, 105.9] | 21.1 MiB | 1.38× [1.19, 1.42] |
| var | 61040 | 106.7% [103.3, 109.0] | 19.3 MiB | 1.27× [1.09, 1.28] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 100983 | 100.0% [100.0, 100.0] | 14.9 MiB | 1.00× [1.00, 1.00] |
| base | 103199 | 102.3% [101.0, 104.3] | 20.5 MiB | 1.37× [1.17, 1.39] |
| var | 102685 | 102.6% [98.9, 104.5] | 19.4 MiB | 1.30× [1.17, 1.32] |

