Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 52005 | 100.0% [100.0, 100.0] | 14.9 MiB | 1.00× [1.00, 1.00] |
| base | 54098 | 104.0% [96.4, 106.8] | 20.8 MiB | 1.39× [1.38, 1.41] |
| var | 55240 | 108.4% [101.2, 111.9] | 20.7 MiB | 1.40× [1.37, 1.44] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 73663 | 100.0% [100.0, 100.0] | 15.0 MiB | 1.00× [1.00, 1.00] |
| base | 79642 | 102.8% [97.6, 111.3] | 20.1 MiB | 1.35× [1.34, 1.36] |
| var | 78076 | 103.8% [99.1, 113.2] | 20.2 MiB | 1.35× [1.34, 1.36] |

## Work per request

Per 1 000 requests served (warm-up included), medians over trials [IQR]. Collections and pause from `/gc-stats` (gcry arms only).

### `/json`

| arm | CPU ms (user + sys) | user ms | sys ms | faults | collections | pause ms |
|---|---:|---:|---:|---:|---:|---:|
| boehm | 18.53 [14.55, 19.58] | 8.86 [7.74, 9.45] | 9.70 [6.81, 10.14] | 1.7 [1.3, 1.9] | — | — |
| base | 16.84 [15.60, 17.71] | 8.01 [7.40, 8.16] | 8.87 [8.16, 9.68] | 2.1 [1.9, 2.3] | 0.711 [0.710, 0.711] | 0.420 [0.391, 0.442] |
| var | 16.86 [14.22, 17.97] | 8.01 [7.13, 8.31] | 8.85 [7.09, 9.58] | 2.2 [1.8, 2.3] | 0.710 [0.710, 0.711] | 0.416 [0.364, 0.439] |

### `/`

| arm | CPU ms (user + sys) | user ms | sys ms | faults | collections | pause ms |
|---|---:|---:|---:|---:|---:|---:|
| boehm | 11.61 [9.64, 12.52] | 3.36 [2.92, 3.49] | 8.30 [6.68, 9.07] | 1.2 [1.0, 1.3] | — | — |
| base | 10.92 [9.19, 12.35] | 3.10 [2.78, 3.44] | 7.82 [6.41, 8.90] | 1.5 [1.2, 1.7] | 0.153 [0.153, 0.154] | 0.091 [0.081, 0.094] |
| var | 10.71 [8.75, 12.31] | 3.14 [2.67, 3.39] | 7.57 [6.08, 8.91] | 1.5 [1.1, 1.7] | 0.153 [0.153, 0.154] | 0.091 [0.077, 0.095] |

