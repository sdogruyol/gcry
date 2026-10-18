Kemal, 20 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 58166 | 100.0% [100.0, 100.0] | 16.6 MiB | 1.00× [1.00, 1.00] |
| base | 64280 | 111.3% [108.9, 113.4] | 21.1 MiB | 1.29× [1.24, 1.39] |
| var | 62549 | 108.3% [105.3, 109.4] | 18.9 MiB | 1.23× [1.07, 1.25] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 106258 | 100.0% [100.0, 100.0] | 17.0 MiB | 1.00× [1.00, 1.00] |
| base | 110577 | 102.2% [101.0, 104.6] | 20.4 MiB | 1.21× [1.12, 1.37] |
| var | 110110 | 103.5% [100.6, 104.9] | 18.9 MiB | 1.11× [1.03, 1.26] |

