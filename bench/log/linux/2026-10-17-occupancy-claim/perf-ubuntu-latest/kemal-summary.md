Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 43402 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 44385 | 101.9% [101.1, 103.2] | 21.0 MiB | 1.39× [1.18, 1.46] |
| var | 46435 | 106.7% [104.9, 109.0] | 20.9 MiB | 1.39× [1.23, 1.46] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 64996 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 65506 | 100.9% [100.2, 101.7] | 20.3 MiB | 1.34× [1.21, 1.36] |
| var | 65463 | 101.0% [99.5, 102.6] | 20.3 MiB | 1.34× [1.20, 1.36] |

