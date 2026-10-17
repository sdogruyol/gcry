Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 80472 | 100.0% [100.0, 100.0] | 14.6 MiB | 1.00× [1.00, 1.00] |
| base | 82452 | 102.3% [101.6, 113.3] | 29.2 MiB | 1.98× [1.95, 2.02] |
| var | 83250 | 103.5% [93.7, 115.4] | 20.8 MiB | 1.39× [1.38, 1.44] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 127050 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 126570 | 101.1% [98.5, 101.6] | 28.8 MiB | 1.91× [1.89, 1.92] |
| var | 128028 | 99.1% [98.7, 105.6] | 20.0 MiB | 1.33× [1.33, 1.36] |

