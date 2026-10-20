Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 1.2 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 76324 | 100.0% [100.0, 100.0] | 14.5 MiB | 1.00× [1.00, 1.00] |
| base | 79274 | 103.9% [102.0, 105.4] | 20.5 MiB | 1.40× [1.39, 1.42] |
| var | 79246 | 103.5% [101.5, 105.3] | 20.2 MiB | 1.39× [1.38, 1.43] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 124294 | 100.0% [100.0, 100.0] | 15.0 MiB | 1.00× [1.00, 1.00] |
| base | 125232 | 101.3% [99.8, 103.3] | 20.2 MiB | 1.34× [1.34, 1.35] |
| var | 124048 | 100.0% [98.9, 101.8] | 20.2 MiB | 1.35× [1.34, 1.37] |

## Work per request

Per 1 000 requests served (warm-up included), medians over trials [IQR]. Collections and pause from `/gc-stats` (gcry arms only).

### `/json`

| arm | CPU ms (user + sys) | user ms | sys ms | faults | collections | pause ms |
|---|---:|---:|---:|---:|---:|---:|
| boehm | 13.05 [13.00, 13.15] | 7.14 [7.13, 7.17] | 5.91 [5.88, 5.97] | 1.1 [1.1, 1.2] | — | — |
| base | 12.41 [12.36, 12.46] | 6.61 [6.57, 6.65] | 5.79 [5.76, 5.84] | 1.5 [1.5, 1.5] | 0.710 [0.710, 0.710] | 0.328 [0.324, 0.330] |
| var | 12.49 [12.39, 12.55] | 6.59 [6.57, 6.61] | 5.91 [5.81, 5.94] | 1.5 [1.5, 1.5] | 0.710 [0.710, 0.711] | 0.316 [0.314, 0.320] |

### `/`

| arm | CPU ms (user + sys) | user ms | sys ms | faults | collections | pause ms |
|---|---:|---:|---:|---:|---:|---:|
| boehm | 7.88 [7.84, 7.99] | 2.48 [2.46, 2.50] | 5.40 [5.39, 5.47] | 0.7 [0.7, 0.7] | — | — |
| base | 7.78 [7.73, 7.81] | 2.38 [2.38, 2.40] | 5.39 [5.36, 5.42] | 0.9 [0.9, 0.9] | 0.153 [0.153, 0.153] | 0.073 [0.072, 0.073] |
| var | 7.78 [7.76, 7.86] | 2.40 [2.37, 2.42] | 5.40 [5.37, 5.42] | 0.9 [0.9, 1.0] | 0.153 [0.153, 0.153] | 0.071 [0.070, 0.071] |

