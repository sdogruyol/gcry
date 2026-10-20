Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 46957 | 100.0% [100.0, 100.0] | 14.9 MiB | 1.00× [1.00, 1.00] |
| base | 49339 | 106.5% [101.8, 110.8] | 20.5 MiB | 1.38× [1.36, 1.44] |
| var | 48836 | 106.5% [99.5, 113.0] | 20.1 MiB | 1.36× [1.35, 1.41] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 60360 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 59979 | 100.4% [98.2, 105.1] | 20.0 MiB | 1.33× [1.32, 1.35] |
| var | 64902 | 105.9% [101.9, 114.0] | 20.2 MiB | 1.35× [1.33, 1.36] |

