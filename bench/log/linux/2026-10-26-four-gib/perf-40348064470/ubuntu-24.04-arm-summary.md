Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.9 MiB.

| bench | base | var | var_env |
|---|---:|---|---|
| JsonGenerate | 2.797 s, 769 MiB | 100% [99, 100] / 1.00× [1.00, 1.00] | 100% [99, 100] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | +0.7% [+0.1%, +1.1%] | +0.4% [-0.1%, +0.8%] | +0.5% [-0.3%, +0.8%] | +0.6% [-3.8%, +7.2%] | -0.2% [-0.5%, -0.1%] | +0.0% [-0.0%, +0.0%] | +1.2% [-0.2%, +1.9%] | +0.0% [+0.0%, +0.0%] | +0.6% [+0.2%, +1.6%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | base | 1.054 | 2.797 | 2.802 | 0.336 | 293119 | 14 | -0.7% [-1.1%, -0.1%] |
| JsonGenerate | var | 1.062 | 2.804 | 2.808 | 0.338 | 292760 | 14 | — |
| JsonGenerate | var_env | 1.064 | 2.799 | 2.814 | 0.337 | 292790 | 14 | +0.1% [-0.3%, +0.6%] |
