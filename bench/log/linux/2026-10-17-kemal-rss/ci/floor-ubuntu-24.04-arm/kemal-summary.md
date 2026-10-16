Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 55776 | 100.0% [100.0, 100.0] | 13.6 MiB | 1.00× [1.00, 1.00] |
| base | 57635 | 103.4% [101.6, 105.1] | 20.3 MiB | 1.50× [1.34, 1.50] |
| var | 58336 | 106.0% [103.3, 107.6] | 16.7 MiB | 1.18× [1.06, 1.29] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 107811 | 100.0% [100.0, 100.0] | 13.6 MiB | 1.00× [1.00, 1.00] |
| base | 109494 | 100.8% [98.3, 104.7] | 19.7 MiB | 1.45× [1.45, 1.45] |
| var | 106812 | 99.2% [95.8, 100.1] | 14.1 MiB | 1.04× [1.04, 1.10] |

