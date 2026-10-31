Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | boehm | base | var | var_env |
|---|---:|---|---|---|
| JsonGenerate | 2.969 s, 1198 MiB | 103% [96, 110] / 0.74× [0.67, 0.74] | 105% [98, 112] / 0.64× [0.64, 0.64] | 104% [96, 111] / 0.74× [0.74, 0.74] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | -0.5% [-9.5%, +11.0%] | -0.7% [-6.9%, +6.5%] | -0.0% [-6.3%, +5.5%] | -1.1% [-16.3%, +32.9%] | -0.0% [-0.3%, +0.3%] | -13.6% [-13.7%, -13.6%] | -0.0% [-7.3%, +10.5%] | +0.0% [+0.0%, +0.0%] | -1.0% [-3.8%, +1.3%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | base | 1.102 | 2.764 | 2.830 | 0.213 | 82390 | 13 | +0.5% [-9.9%, +10.5%] |
| JsonGenerate | var | 1.115 | 2.736 | 2.750 | 0.231 | 82356 | 13 | — |
| JsonGenerate | boehm | 1.193 | 2.969 | 3.105 | 0.260 | 76903 | n/a | +4.1% [-5.8%, +13.3%] |
| JsonGenerate | var_env | 1.094 | 2.742 | 2.823 | 0.263 | 82330 | 13 | +0.2% [-10.7%, +11.0%] |
