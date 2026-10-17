Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 0.5 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 18629 | 100.0% [100.0, 100.0] | 10.4 MiB | 1.00× [1.00, 1.00] |
| base | 20956 | 108.1% [105.4, 118.6] | 22.9 MiB | 2.19× [2.19, 2.21] |
| var | 21488 | 112.7% [107.9, 119.9] | 23.0 MiB | 2.20× [2.18, 2.22] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 33315 | 100.0% [100.0, 100.0] | 10.4 MiB | 1.00× [1.00, 1.00] |
| base | 35081 | 104.4% [99.5, 110.9] | 23.0 MiB | 2.22× [2.21, 2.22] |
| var | 35352 | 104.1% [100.4, 109.8] | 23.0 MiB | 2.22× [2.21, 2.22] |

