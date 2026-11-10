Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 53389 | 100.0% [100.0, 100.0] | 14.6 MiB | 1.00× [1.00, 1.00] |
| base | 57709 | 102.5% [94.2, 112.7] | 20.7 MiB | 1.40× [1.36, 1.46] |
| var | 58796 | 106.0% [101.3, 115.1] | 20.6 MiB | 1.39× [1.36, 1.43] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 69027 | 100.0% [100.0, 100.0] | 15.0 MiB | 1.00× [1.00, 1.00] |
| base | 72954 | 104.8% [99.5, 111.4] | 20.5 MiB | 1.36× [1.35, 1.36] |
| var | 67933 | 99.1% [90.7, 103.5] | 20.0 MiB | 1.33× [1.33, 1.35] |

## Work per request

Per 1 000 requests served (warm-up included), medians over trials [IQR]. Collections and pause from `/gc-stats` (gcry arms only).

### `/json`

| arm | CPU ms (user + sys) | user ms | sys ms | faults | collections | pause ms |
|---|---:|---:|---:|---:|---:|---:|
| boehm | 18.05 [16.72, 18.72] | 8.50 [8.01, 9.04] | 9.31 [8.75, 9.75] | 1.7 [1.5, 1.7] | — | — |
| base | 16.22 [15.50, 17.77] | 7.68 [7.13, 7.91] | 9.18 [8.01, 9.74] | 2.1 [2.0, 2.3] | 0.711 [0.710, 0.711] | 0.413 [0.382, 0.421] |
| var | 16.10 [15.12, 16.95] | 7.19 [6.95, 7.63] | 9.09 [7.94, 9.42] | 2.0 [1.9, 2.2] | 0.710 [0.710, 0.711] | 0.282 [0.274, 0.291] |

### `/`

| arm | CPU ms (user + sys) | user ms | sys ms | faults | collections | pause ms |
|---|---:|---:|---:|---:|---:|---:|
| boehm | 12.19 [10.52, 13.26] | 3.26 [2.92, 3.72] | 8.93 [7.50, 9.51] | 1.3 [1.1, 1.4] | — | — |
| base | 11.76 [10.51, 12.29] | 3.11 [2.87, 3.27] | 8.55 [7.54, 9.01] | 1.6 [1.4, 1.8] | 0.153 [0.153, 0.154] | 0.095 [0.088, 0.098] |
| var | 11.97 [10.68, 13.14] | 3.20 [2.80, 3.68] | 8.83 [7.79, 9.41] | 1.7 [1.4, 1.8] | 0.153 [0.153, 0.154] | 0.067 [0.060, 0.069] |

