Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | boehm | boehm1 | gcry | gcry0 | gcry8m | gcry1 |
|---|---:|---|---|---|---|---|
| Binarytrees | 1.081 s, 39 MiB | 100% [90, 108] / 1.00× [1.00, 1.00] | 96% [89, 105] / 0.94× [0.94, 0.94] | 97% [91, 102] / 0.94× [0.94, 0.94] | 97% [88, 105] / 0.94× [0.94, 0.94] | 97% [89, 105] / 0.94× [0.94, 0.94] |

Per arm, medians over reps (last column: timed section against `boehm`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs boehm |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | boehm | 1.070 | 1.081 | 1.054 | 0.037 | 2718 | n/a | — |
| Binarytrees | boehm1 | 1.077 | 1.087 | 0.992 | 0.023 | 2710 | n/a | +0.2% [-8.1%, +10.8%] |
| Binarytrees | gcry | 1.069 | 1.075 | 1.001 | 0.061 | 4518 | 184 | +5.4% [-4.4%, +12.8%] |
| Binarytrees | gcry0 | 1.056 | 1.067 | 1.033 | 0.067 | 5024 | 181 | +4.2% [-2.4%, +10.4%] |
| Binarytrees | gcry8m | 1.042 | 1.050 | 0.984 | 0.059 | 4726 | 186 | +3.6% [-3.8%, +13.6%] |
| Binarytrees | gcry1 | 1.056 | 1.065 | 0.972 | 0.062 | 4566 | 188 | +4.0% [-4.6%, +12.3%] |
