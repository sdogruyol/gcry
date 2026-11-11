Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.3 MiB.

| bench | boehm | boehm1 | gcry | gcry0 | gcry8m | gcry1 |
|---|---:|---|---|---|---|---|
| Binarytrees | 0.900 s, 50 MiB | 101% [100, 102] / 1.00× [1.00, 1.00] | 92% [90, 93] / 0.74× [0.74, 0.74] | 92% [90, 93] / 0.74× [0.73, 0.74] | 91% [90, 93] / 0.74× [0.74, 0.74] | 91% [90, 94] / 0.74× [0.74, 0.74] |

Per arm, medians over reps (last column: timed section against `boehm`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs boehm |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | boehm | 0.892 | 0.900 | 0.893 | 0.044 | 12178 | n/a | — |
| Binarytrees | boehm1 | 0.879 | 0.887 | 0.856 | 0.031 | 12165 | n/a | -1.1% [-2.2%, -0.1%] |
| Binarytrees | gcry | 0.973 | 0.980 | 0.934 | 0.047 | 14998 | 232 | +8.8% [+7.3%, +11.0%] |
| Binarytrees | gcry0 | 0.972 | 0.978 | 1.081 | 0.047 | 15226 | 233 | +9.4% [+7.7%, +11.1%] |
| Binarytrees | gcry8m | 0.976 | 0.983 | 0.939 | 0.049 | 15210 | 230 | +10.2% [+7.5%, +11.9%] |
| Binarytrees | gcry1 | 0.974 | 0.982 | 0.937 | 0.046 | 15111 | 232 | +9.7% [+7.0%, +11.8%] |
