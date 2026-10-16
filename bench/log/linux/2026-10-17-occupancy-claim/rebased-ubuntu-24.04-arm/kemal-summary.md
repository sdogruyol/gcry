Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: VmHWM.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 56098 | 100.0% [100.0, 100.0] | 13.6 MiB | 1.00× [1.00, 1.00] |
| base | 57560 | 102.2% [100.5, 105.9] | 18.1 MiB | 1.33× [1.19, 1.34] |
| var | 60081 | 105.6% [104.4, 107.7] | 18.1 MiB | 1.33× [1.19, 1.34] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 105611 | 100.0% [100.0, 100.0] | 13.6 MiB | 1.00× [1.00, 1.00] |
| base | 106444 | 101.5% [98.5, 102.8] | 18.2 MiB | 1.34× [1.34, 1.34] |
| var | 108491 | 101.8% [100.5, 104.1] | 18.2 MiB | 1.34× [1.34, 1.35] |

