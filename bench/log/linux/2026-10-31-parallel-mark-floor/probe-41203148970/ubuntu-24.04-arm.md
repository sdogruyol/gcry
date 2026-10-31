Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.9 MiB.

| bench | boehm | boehm1 | gcry | gcry0 | gcry8m | gcry1 |
|---|---:|---|---|---|---|---|
| Binarytrees | 1.041 s, 50 MiB | 102% [101, 104] / 1.00× [1.00, 1.00] | 96% [95, 98] / 0.73× [0.73, 0.73] | 97% [96, 99] / 0.70× [0.70, 0.71] | 97% [95, 98] / 0.73× [0.73, 0.73] | 96% [94, 98] / 0.73× [0.73, 0.73] |

Per arm, medians over reps (last column: timed section against `boehm`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs boehm |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | boehm | 1.032 | 1.041 | 1.036 | 0.032 | 12138 | n/a | — |
| Binarytrees | boehm1 | 1.003 | 1.013 | 0.989 | 0.025 | 12128 | n/a | -2.1% [-3.9%, -1.0%] |
| Binarytrees | gcry | 1.068 | 1.075 | 1.037 | 0.040 | 15304 | 232 | +4.1% [+2.1%, +5.5%] |
| Binarytrees | gcry0 | 1.066 | 1.073 | 1.072 | 0.038 | 15058 | 232 | +3.5% [+1.4%, +4.8%] |
| Binarytrees | gcry8m | 1.066 | 1.073 | 1.040 | 0.038 | 15430 | 231 | +3.5% [+1.7%, +6.0%] |
| Binarytrees | gcry1 | 1.071 | 1.078 | 1.039 | 0.037 | 16034 | 228 | +4.3% [+1.9%, +6.2%] |
