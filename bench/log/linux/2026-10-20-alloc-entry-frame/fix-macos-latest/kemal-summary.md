Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 47892 | 100.0% [100.0, 100.0] | 14.3 MiB | 1.00× [1.00, 1.00] |
| base | 50877 | 107.0% [101.1, 113.5] | 20.6 MiB | 1.44× [1.40, 1.74] |
| var | 50149 | 106.0% [102.9, 110.7] | 20.2 MiB | 1.43× [1.40, 1.44] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 61670 | 100.0% [100.0, 100.0] | 14.9 MiB | 1.00× [1.00, 1.00] |
| base | 66776 | 105.7% [100.2, 107.2] | 20.0 MiB | 1.35× [1.34, 1.36] |
| var | 62271 | 100.8% [92.7, 102.9] | 20.0 MiB | 1.34× [1.34, 1.35] |

## Work per request

Per 1 000 requests served (warm-up included), medians over trials [IQR]. Collections and pause from `/gc-stats` (gcry arms only).

### `/json`

| arm | CPU ms (user + sys) | user ms | sys ms | faults | collections | pause ms |
|---|---:|---:|---:|---:|---:|---:|
| boehm | 19.82 [18.66, 20.68] | 9.36 [8.88, 9.78] | 10.37 [9.79, 10.90] | 1.8 [1.7, 1.9] | — | — |
| base | 18.38 [17.64, 18.68] | 8.26 [7.89, 8.45] | 10.12 [9.75, 10.22] | 2.4 [2.3, 2.7] | 0.710 [0.710, 0.711] | 0.457 [0.439, 0.466] |
| var | 18.80 [17.57, 18.99] | 8.38 [8.02, 8.52] | 10.33 [9.55, 10.43] | 2.4 [2.2, 2.4] | 0.711 [0.711, 0.711] | 0.449 [0.427, 0.463] |

### `/`

| arm | CPU ms (user + sys) | user ms | sys ms | faults | collections | pause ms |
|---|---:|---:|---:|---:|---:|---:|
| boehm | 13.71 [12.55, 14.01] | 3.86 [3.50, 3.92] | 9.85 [9.08, 10.09] | 1.5 [1.4, 1.5] | — | — |
| base | 12.52 [12.23, 13.44] | 3.40 [3.31, 3.72] | 9.10 [8.93, 9.72] | 1.8 [1.7, 1.9] | 0.153 [0.153, 0.154] | 0.100 [0.096, 0.104] |
| var | 13.48 [12.49, 13.90] | 3.75 [3.45, 3.90] | 9.73 [9.10, 9.97] | 1.8 [1.7, 1.9] | 0.154 [0.153, 0.154] | 0.098 [0.095, 0.106] |

