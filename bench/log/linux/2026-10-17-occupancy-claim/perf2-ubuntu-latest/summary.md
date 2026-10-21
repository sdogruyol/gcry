Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.3 MiB.

| bench | boehm | base | var | var_env |
|---|---:|---|---|---|
| Knuckeotide | 0.851 s, 43 MiB | 83% [81, 85] / 1.40× [1.29, 1.64] | 90% [88, 92] / 1.96× [1.73, 2.06] | 90% [88, 92] / 1.88× [1.67, 1.94] |
| JsonParseSerializable | 1.099 s, 564 MiB | 89% [89, 93] / 0.78× [0.77, 0.82] | 90% [89, 92] / 0.83× [0.78, 0.87] | 89% [88, 91] / 0.73× [0.71, 0.77] |
| JsonParsePull | 1.093 s, 532 MiB | 93% [91, 94] / 0.82× [0.77, 0.86] | 92% [91, 94] / 0.88× [0.84, 0.91] | 90% [89, 92] / 0.78× [0.77, 0.82] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Knuckeotide | -8.5% [-9.8%, -6.7%] | -7.6% [-8.6%, -6.1%] | -5.9% [-8.8%, -4.5%] | -15.8% [-27.6%, +1.9%] | -7.4% [-16.1%, -0.2%] | +34.8% [+11.2%, +41.7%] | -32.1% [-41.7%, -27.2%] | -28.3% [-29.4%, -26.7%] | -23.3% [-27.2%, -17.9%] |
| JsonParseSerializable | -2.8% [-3.5%, -1.4%] | +0.1% [-1.7%, +1.3%] | -1.2% [-2.3%, +1.3%] | +9.3% [+5.4%, +10.2%] | +4.1% [-0.2%, +4.5%] | +7.1% [+1.5%, +7.8%] | +3.1% [-5.8%, +15.9%] | +0.0% [+0.0%, +0.0%] | -0.2% [-4.0%, +0.5%] |
| JsonParsePull | -1.6% [-2.7%, +0.0%] | +0.6% [-1.6%, +1.7%] | -1.2% [-5.0%, +0.3%] | +10.4% [+4.5%, +14.0%] | +4.7% [+1.2%, +4.9%] | +7.4% [+2.3%, +7.6%] | +0.5% [-13.1%, +6.7%] | +0.0% [+0.0%, +0.0%] | -1.3% [-4.6%, -0.3%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Knuckeotide | base | 0.931 | 1.026 | 0.962 | 0.067 | 39056 | 53 | +9.3% [+7.2%, +10.9%] |
| Knuckeotide | var | 0.858 | 0.954 | 0.909 | 0.059 | 33855 | 38 | — |
| Knuckeotide | boehm | 0.769 | 0.851 | 0.862 | 0.017 | 3285 | n/a | -10.0% [-10.7%, -7.9%] |
| Knuckeotide | var_env | 0.848 | 0.944 | 0.894 | 0.056 | 33540 | 38 | +0.2% [-2.5%, +1.2%] |
| JsonParseSerializable | base | 0.394 | 1.221 | 1.075 | 0.216 | 148064 | 13 | +2.9% [+1.4%, +3.6%] |
| JsonParseSerializable | var | 0.385 | 1.229 | 1.061 | 0.230 | 145415 | 13 | — |
| JsonParseSerializable | boehm | 0.332 | 1.099 | 1.346 | 0.056 | 16816 | n/a | -13.8% [-14.6%, -12.6%] |
| JsonParseSerializable | var_env | 0.388 | 1.235 | 1.116 | 0.212 | 137170 | 18 | +1.3% [+0.5%, +4.1%] |
| JsonParsePull | base | 0.378 | 1.186 | 1.049 | 0.202 | 132483 | 12 | +1.6% [-0.0%, +2.7%] |
| JsonParsePull | var | 0.374 | 1.187 | 1.037 | 0.214 | 139503 | 12 | — |
| JsonParsePull | boehm | 0.323 | 1.093 | 1.343 | 0.057 | 16767 | n/a | -12.6% [-13.7%, -11.8%] |
| JsonParsePull | var_env | 0.370 | 1.212 | 1.105 | 0.196 | 131315 | 17 | +0.0% [-2.3%, +4.4%] |
