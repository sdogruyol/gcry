Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.5 MiB.

| bench | boehm | base | var | var_env |
|---|---:|---|---|---|
| JsonGenerate | 4.206 s, 1194 MiB | 101% [100, 104] / 0.65× [0.64, 0.65] | 101% [98, 103] / 0.65× [0.63, 0.65] | 101% [100, 103] / 0.65× [0.64, 0.65] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | +2.4% [+1.4%, +4.7%] | +1.2% [-0.9%, +2.3%] | +1.0% [-1.1%, +1.9%] | +2.0% [-3.6%, +7.6%] | -0.0% [-0.3%, +0.2%] | -0.1% [-1.9%, -0.0%] | -0.7% [-7.5%, +1.5%] | +0.0% [+0.0%, +0.0%] | -0.5% [-5.7%, +0.6%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | base | 1.758 | 4.138 | 4.066 | 0.493 | 328014 | 14 | -2.3% [-4.5%, -1.4%] |
| JsonGenerate | var | 1.811 | 4.183 | 4.061 | 0.494 | 327901 | 14 | — |
| JsonGenerate | boehm | 1.862 | 4.206 | 4.294 | 0.413 | 305995 | n/a | +2.8% [+1.1%, +5.0%] |
| JsonGenerate | var_env | 1.787 | 4.127 | 4.027 | 0.488 | 327912 | 14 | +0.3% [-2.1%, +0.9%] |
