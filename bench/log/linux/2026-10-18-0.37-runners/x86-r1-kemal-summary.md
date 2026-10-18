Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 70148 | 100.0% [100.0, 100.0] | 17.8 MiB | 1.00× [1.00, 1.00] |
| base | 73383 | 105.2% [103.2, 107.8] | 21.1 MiB | 1.18× [1.12, 1.36] |
| var | 72143 | 102.9% [102.2, 103.7] | 18.9 MiB | 1.06× [1.00, 1.23] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 97127 | 100.0% [100.0, 100.0] | 17.8 MiB | 1.00× [1.00, 1.00] |
| base | 96360 | 99.2% [98.8, 101.3] | 20.4 MiB | 1.15× [1.13, 1.37] |
| var | 96773 | 100.5% [99.3, 101.3] | 18.9 MiB | 1.06× [1.03, 1.26] |

