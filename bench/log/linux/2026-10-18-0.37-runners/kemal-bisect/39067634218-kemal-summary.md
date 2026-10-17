Kemal, 25 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 36849 | 100.0% [100.0, 100.0] | 15.4 MiB | 1.00× [1.00, 1.00] |
| base | 38174 | 103.9% [101.0, 106.9] | 18.7 MiB | 1.22× [1.03, 1.25] |
| var | 39093 | 104.7% [100.1, 108.4] | 18.7 MiB | 1.22× [1.03, 1.29] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 64095 | 100.0% [100.0, 100.0] | 15.2 MiB | 1.00× [1.00, 1.00] |
| base | 65564 | 102.1% [99.5, 103.7] | 18.6 MiB | 1.23× [1.06, 1.26] |
| var | 64981 | 101.4% [97.7, 105.3] | 18.7 MiB | 1.23× [1.06, 1.26] |

