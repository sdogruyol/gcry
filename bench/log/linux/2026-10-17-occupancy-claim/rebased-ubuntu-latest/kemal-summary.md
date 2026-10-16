Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 37592 | 100.0% [100.0, 100.0] | 15.3 MiB | 1.00× [1.00, 1.00] |
| base | 39582 | 105.3% [100.2, 108.9] | 18.7 MiB | 1.23× [1.04, 1.24] |
| var | 38700 | 100.0% [98.8, 105.1] | 18.7 MiB | 1.23× [1.04, 1.24] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 63999 | 100.0% [100.0, 100.0] | 16.1 MiB | 1.00× [1.00, 1.00] |
| base | 66518 | 105.3% [101.7, 109.1] | 18.8 MiB | 1.17× [1.06, 1.26] |
| var | 64936 | 101.5% [99.2, 106.8] | 18.8 MiB | 1.17× [1.06, 1.26] |

