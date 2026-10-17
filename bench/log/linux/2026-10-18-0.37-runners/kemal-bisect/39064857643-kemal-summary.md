Kemal, 20 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 69962 | 100.0% [100.0, 100.0] | 18.1 MiB | 1.00× [1.00, 1.00] |
| base | 74004 | 106.2% [104.5, 108.8] | 21.1 MiB | 1.17× [1.12, 1.44] |
| var | 73234 | 105.6% [103.9, 107.0] | 21.1 MiB | 1.17× [1.13, 1.45] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 96221 | 100.0% [100.0, 100.0] | 16.9 MiB | 1.00× [1.00, 1.00] |
| base | 97768 | 100.7% [98.5, 103.0] | 20.4 MiB | 1.21× [1.14, 1.35] |
| var | 96385 | 99.3% [97.8, 100.5] | 20.4 MiB | 1.26× [1.14, 1.36] |

