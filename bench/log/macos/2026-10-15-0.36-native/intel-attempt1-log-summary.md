Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.5 MiB.

| bench | boehm | base | var |
|---|---:|---|---|
| Primes | 2.076 s, 667 MiB | 86% [81, 89] / 0.91× [0.91, 0.91] | 91% [88, 96] / 0.91× [0.91, 0.91] |
| JsonParsePure | 2.880 s, 683 MiB | 84% [79, 91] / 0.85× [0.83, 0.90] | 92% [86, 95] / 0.81× [0.80, 0.81] |
| Binarytrees | 2.318 s, 36 MiB | 91% [88, 97] / 1.87× [1.87, 1.87] | 91% [86, 96] / 1.87× [1.87, 1.87] |
| JsonGenerate | 5.031 s, 1194 MiB | 94% [89, 102] / 0.72× [0.65, 0.73] | 92% [87, 98] / 0.65× [0.59, 0.65] |
| JsonParseSerializable | 3.484 s, 547 MiB | 94% [85, 95] / 0.91× [0.89, 0.94] | 94% [91, 99] / 0.85× [0.84, 0.86] |
| JsonParsePull | 3.490 s, 512 MiB | 98% [90, 104] / 0.95× [0.90, 0.98] | 97% [95, 101] / 0.91× [0.87, 0.92] |
| Revcomp | 4.799 s, 996 MiB | 91% [90, 95] / 0.65× [0.57, 0.70] | 91% [89, 97] / 0.59× [0.54, 0.68] |
| RegexDna | 4.231 s, 594 MiB | 96% [89, 99] / 0.53× [0.48, 0.55] | 96% [93, 101] / 0.50× [0.48, 0.57] |
| Knuckeotide | 2.366 s, 45 MiB | 88% [84, 92] / 2.09× [2.04, 2.18] | 90% [88, 92] / 2.01× [1.99, 2.06] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark |
|---|---:|---:|---:|---:|
| Primes | -5.5% [-8.1%, -2.0%] | -5.4% [-8.0%, -1.9%] | -0.3% [-0.4%, -0.1%] | -24.6% [-30.2%, -20.3%] |
| JsonParsePure | -5.8% [-12.1%, -0.3%] | -4.1% [-12.5%, +1.4%] | -4.6% [-10.0%, -3.8%] | -20.9% [-22.4%, -1.8%] |
| Binarytrees | +1.8% [-5.1%, +5.6%] | +2.0% [-5.0%, +5.9%] | -0.2% [-0.2%, -0.2%] | +17.3% [-8.9%, +43.2%] |
| JsonGenerate | +4.7% [-1.8%, +14.0%] | -0.5% [-4.1%, +8.8%] | -10.1% [-11.4%, -9.9%] | -0.8% [-8.6%, +17.8%] |
| JsonParseSerializable | -3.6% [-6.6%, +6.5%] | -0.7% [-6.7%, +0.9%] | -8.4% [-10.2%, -5.0%] | -4.6% [-25.6%, +4.2%] |
| JsonParsePull | -0.3% [-3.4%, +2.4%] | -1.9% [-4.0%, +2.9%] | -4.2% [-6.7%, -3.3%] | -8.1% [-17.2%, +5.0%] |
| Revcomp | -1.6% [-5.9%, +6.8%] | +0.3% [-5.4%, +3.4%] | -2.6% [-16.7%, +14.3%] | -3.5% [-7.9%, +3.5%] |
| RegexDna | +1.2% [-4.7%, +9.9%] | -0.6% [-4.4%, +4.4%] | +2.6% [-9.5%, +8.4%] | -1.5% [-6.4%, +8.3%] |
| Knuckeotide | -2.3% [-5.5%, +1.9%] | -2.8% [-6.9%, +1.8%] | -3.2% [-7.5%, -0.2%] | +6.1% [-0.2%, +18.6%] |

AB Primes: mark 333 -> 245 ms (-26.3%); time 2.519 -> 2.226 s (-11.6%)
AB JsonParsePure: mark 374 -> 300 ms (-19.8%); time 1.824 -> 1.689 s (-7.4%)
AB Binarytrees: mark 50 -> 65 ms (+28.2%); time 2.733 -> 2.655 s (-2.9%)
AB JsonGenerate: mark 587 -> 635 ms (+8.3%); time 2.086 -> 2.255 s (+8.1%)
AB JsonParseSerializable: mark 188 -> 163 ms (-13.5%); time 1.584 -> 1.487 s (-6.1%)
AB JsonParsePull: mark 168 -> 158 ms (-6.1%); time 1.517 -> 1.467 s (-3.3%)
AB Revcomp: mark 1 -> 1 ms (-4.2%); time 2.234 -> 2.160 s (-3.3%)
AB RegexDna: mark 0 -> 0 ms (+8.1%); time 3.140 -> 3.183 s (+1.4%)
AB Knuckeotide: mark 18 -> 19 ms (+6.1%); time 2.518 -> 2.653 s (+5.4%)
I: Resolving dependencies
I: Fetching https://github.com/kemalcr/kemal.git
I: Fetching https://github.com/luislavena/radix.git
I: Fetching https://github.com/crystal-loot/exception_page.git
I: Fetching https://github.com/sija/backtracer.cr.git
I: Installing radix (0.4.1)
I: Installing backtracer (1.2.4)
I: Installing exception_page (0.5.0)
I: Installing kemal (1.14.0)
I: Installing gcry (0.36.0 at ../..)
I: Writing shard.lock
ld: warning: REFERENCED_DYNAMICALLY flag on symbol '_catch_exception_raise' is deprecated
ld: warning: REFERENCED_DYNAMICALLY flag on symbol '_catch_exception_raise_state' is deprecated
ld: warning: REFERENCED_DYNAMICALLY flag on symbol '_catch_exception_raise_state_identity' is deprecated
Kemal, 15 trials, wrk -t2 -c50 10 s after 3 s warm-up; cells: req/s as % of boehm and peak RSS × boehm, medians of per-trial paired ratios [IQR]. Peak RSS: ru_maxrss; floor of the method (`true`): 0.5 MiB.

## `/json`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 30211 | 100.0% [100.0, 100.0] | 10.4 MiB | 1.00× [1.00, 1.00] |
| base | 30787 | 108.0% [99.7, 110.4] | 23.1 MiB | 2.21× [2.20, 2.23] |
| var | 32418 | 108.7% [100.4, 110.8] | 23.0 MiB | 2.20× [2.20, 2.22] |

## `/`

| arm | req/s (median) | % of boehm | peak RSS | × boehm |
|---|---:|---:|---:|---:|
| boehm | 54425 | 100.0% [100.0, 100.0] | 10.4 MiB | 1.00× [1.00, 1.00] |
| base | 57078 | 97.6% [94.4, 106.4] | 23.1 MiB | 2.23× [2.22, 2.23] |
| var | 53444 | 98.2% [90.9, 104.8] | 22.9 MiB | 2.21× [2.20, 2.22] |


