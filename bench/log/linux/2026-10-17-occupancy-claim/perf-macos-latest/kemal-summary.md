Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 57408 | 100.0% [100.0, 100.0] | 15.0 MiB | 1.00× [1.00, 1.00] |
| base | 58793 | 109.7% [102.1, 116.3] | 25.1 MiB | 1.67× [1.66, 1.69] |
| var | 60744 | 103.7% [98.7, 109.0] | 25.1 MiB | 1.69× [1.67, 1.70] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 76554 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 87099 | 103.6% [98.8, 116.3] | 24.9 MiB | 1.66× [1.64, 1.68] |
| var | 73495 | 108.0% [100.0, 115.9] | 25.0 MiB | 1.67× [1.65, 1.68] |

