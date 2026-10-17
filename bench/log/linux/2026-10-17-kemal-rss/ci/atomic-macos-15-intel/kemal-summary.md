Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 0.5 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 19890 | 100.0% [100.0, 100.0] | 10.4 MiB | 1.00× [1.00, 1.00] |
| base | 21647 | 109.1% [106.8, 114.3] | 16.4 MiB | 1.58× [1.56, 1.59] |
| var | 22539 | 110.3% [104.8, 117.4] | 15.0 MiB | 1.44× [1.43, 1.44] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 35626 | 100.0% [100.0, 100.0] | 10.4 MiB | 1.00× [1.00, 1.00] |
| base | 37574 | 113.3% [93.6, 117.0] | 16.4 MiB | 1.59× [1.58, 1.59] |
| var | 38755 | 102.9% [97.2, 112.9] | 15.0 MiB | 1.45× [1.44, 1.46] |

