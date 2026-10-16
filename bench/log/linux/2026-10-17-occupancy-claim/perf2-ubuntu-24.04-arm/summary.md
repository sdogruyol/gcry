Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.9 MiB.

| bench | boehm | base | var | var_env |
|---|---:|---|---|---|
| Knuckeotide | 1.235 s, 42 MiB | 89% [88, 90] / 1.30× [1.15, 1.54] | 92% [91, 92] / 1.93× [1.59, 2.03] | 91% [91, 93] / 1.84× [1.59, 1.96] |
| JsonParseSerializable | 1.686 s, 495 MiB | 98% [98, 98] / 0.85× [0.85, 0.89] | 99% [99, 100] / 0.92× [0.91, 0.97] | 97% [96, 97] / 0.84× [0.83, 0.88] |
| JsonParsePull | 1.679 s, 485 MiB | 98% [98, 99] / 0.86× [0.84, 0.87] | 99% [99, 100] / 0.94× [0.91, 0.96] | 98% [97, 98] / 0.85× [0.82, 0.86] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Knuckeotide | -3.9% [-4.5%, -3.0%] | -3.5% [-4.2%, -2.7%] | -3.3% [-3.7%, -2.7%] | +0.2% [-9.1%, +12.6%] | +0.5% [-10.3%, +15.7%] | +40.3% [+30.4%, +52.3%] | -35.5% [-40.0%, -31.2%] | -28.1% [-29.3%, -26.8%] | -21.8% [-28.7%, -18.6%] |
| JsonParseSerializable | -1.1% [-1.4%, -0.8%] | -1.0% [-1.6%, -0.5%] | -1.7% [-2.3%, -1.1%] | +4.0% [-3.3%, +8.4%] | +4.5% [+4.5%, +4.7%] | +8.0% [+7.9%, +8.3%] | -0.9% [-1.5%, -0.6%] | +0.0% [+0.0%, +0.0%] | +0.4% [+0.2%, +0.5%] |
| JsonParsePull | -1.2% [-1.5%, -0.8%] | -0.5% [-0.9%, -0.1%] | -1.4% [-1.7%, -0.5%] | +7.8% [+0.6%, +13.2%] | +4.8% [+4.7%, +5.3%] | +8.2% [+7.9%, +9.0%] | +0.8% [-1.2%, +1.3%] | +0.0% [+0.0%, +0.0%] | +0.5% [+0.3%, +0.9%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Knuckeotide | base | 1.299 | 1.396 | 1.353 | 0.043 | 29763 | 57 | +4.0% [+3.1%, +4.8%] |
| Knuckeotide | var | 1.250 | 1.347 | 1.311 | 0.044 | 29905 | 41 | — |
| Knuckeotide | boehm | 1.140 | 1.235 | 1.224 | 0.027 | 10213 | n/a | -8.7% [-9.2%, -8.2%] |
| Knuckeotide | var_env | 1.253 | 1.351 | 1.316 | 0.038 | 29735 | 41 | +0.5% [-0.6%, +0.9%] |
| JsonParseSerializable | base | 0.662 | 1.723 | 1.637 | 0.173 | 141813 | 13 | +1.1% [+0.8%, +1.4%] |
| JsonParseSerializable | var | 0.654 | 1.704 | 1.613 | 0.178 | 148376 | 13 | — |
| JsonParseSerializable | boehm | 0.608 | 1.686 | 1.664 | 0.151 | 126072 | n/a | -7.0% [-7.4%, -6.2%] |
| JsonParseSerializable | var_env | 0.653 | 1.740 | 1.716 | 0.160 | 137169 | 18 | +0.0% [-0.5%, +0.5%] |
| JsonParsePull | base | 0.651 | 1.703 | 1.638 | 0.156 | 135873 | 12 | +1.2% [+0.8%, +1.5%] |
| JsonParsePull | var | 0.644 | 1.695 | 1.615 | 0.166 | 142478 | 12 | — |
| JsonParsePull | boehm | 0.599 | 1.679 | 1.660 | 0.150 | 123590 | n/a | -7.0% [-7.1%, -6.6%] |
| JsonParsePull | var_env | 0.641 | 1.721 | 1.709 | 0.154 | 131314 | 17 | +0.0% [-0.7%, +0.2%] |
