Kemal, 20 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 56220 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 59516 | 106.0% [104.5, 108.2] | 18.9 MiB | 1.25× [1.12, 1.30] |
| var | 59389 | 104.8% [103.1, 106.9] | 18.9 MiB | 1.25× [1.12, 1.30] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 102901 | 100.0% [100.0, 100.0] | 15.0 MiB | 1.00× [1.00, 1.00] |
| base | 104904 | 102.1% [100.6, 103.4] | 18.9 MiB | 1.26× [1.15, 1.29] |
| var | 105271 | 102.3% [100.9, 103.8] | 18.9 MiB | 1.26× [1.15, 1.29] |

