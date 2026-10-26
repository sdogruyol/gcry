Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | base | var | var_env |
|---|---:|---|---|
| JsonGenerate | 2.729 s, 892 MiB | 95% [89, 108] / 1.00× [0.86, 1.18] | 100% [93, 109] / 1.00× [0.86, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | +1.4% [-7.0%, +11.9%] | +5.4% [-7.2%, +11.9%] | +1.5% [-7.3%, +8.0%] | +11.1% [-19.5%, +35.8%] | -0.0% [-0.2%, +0.3%] | +0.0% [-13.6%, +18.4%] | -0.3% [-6.7%, +10.8%] | +0.0% [-6.8%, +0.0%] | -0.0% [-1.9%, +2.3%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | base | 1.057 | 2.729 | 2.669 | 0.255 | 82358 | 13 | -1.4% [-10.6%, +7.6%] |
| JsonGenerate | var | 1.067 | 2.707 | 2.676 | 0.288 | 82325 | 13 | — |
| JsonGenerate | var_env | 1.071 | 2.733 | 2.594 | 0.241 | 82328 | 13 | -4.6% [-12.0%, +9.8%] |
