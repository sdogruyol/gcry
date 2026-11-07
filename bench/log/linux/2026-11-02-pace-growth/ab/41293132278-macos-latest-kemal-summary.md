Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 58152 | 100.0% [100.0, 100.0] | 14.9 MiB | 1.00× [1.00, 1.00] |
| base | 60929 | 101.0% [95.8, 110.7] | 20.5 MiB | 1.36× [1.34, 1.39] |
| var | 59920 | 101.4% [92.6, 116.8] | 20.0 MiB | 1.37× [1.34, 1.38] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 92571 | 100.0% [100.0, 100.0] | 15.1 MiB | 1.00× [1.00, 1.00] |
| base | 91185 | 95.0% [94.1, 103.0] | 20.0 MiB | 1.33× [1.32, 1.35] |
| var | 82612 | 103.7% [90.8, 109.8] | 20.3 MiB | 1.34× [1.32, 1.35] |

## Work per request

Per 1 000 requests served (warm-up included), medians over trials [IQR]. Collections and pause from `/gc-stats` (gcry arms only).

### `/json`

| arm | CPU ms (user + sys) | user ms | sys ms | faults | collections | pause ms |
|---|---:|---:|---:|---:|---:|---:|
| boehm | 16.18 [15.49, 17.49] | 7.92 [7.69, 8.40] | 8.34 [7.78, 9.29] | 1.5 [1.4, 1.6] | — | — |
| base | 15.19 [14.53, 16.74] | 7.21 [6.91, 7.37] | 7.97 [7.52, 9.29] | 1.9 [1.8, 2.1] | 0.711 [0.710, 0.711] | 0.275 [0.259, 0.290] |
| var | 15.19 [14.04, 17.31] | 6.95 [6.78, 7.73] | 8.55 [7.19, 9.57] | 1.9 [1.7, 2.2] | 0.711 [0.710, 0.711] | 0.269 [0.259, 0.293] |

### `/`

| arm | CPU ms (user + sys) | user ms | sys ms | faults | collections | pause ms |
|---|---:|---:|---:|---:|---:|---:|
| boehm | 9.68 [9.37, 11.80] | 2.81 [2.75, 3.18] | 6.90 [6.65, 8.66] | 1.0 [0.9, 1.3] | — | — |
| base | 9.66 [9.06, 11.65] | 2.71 [2.59, 3.12] | 6.92 [6.47, 8.55] | 1.3 [1.2, 1.7] | 0.153 [0.153, 0.153] | 0.058 [0.056, 0.066] |
| var | 10.18 [8.99, 10.99] | 2.81 [2.56, 2.98] | 7.40 [6.46, 7.92] | 1.4 [1.2, 1.5] | 0.153 [0.153, 0.154] | 0.061 [0.056, 0.063] |

