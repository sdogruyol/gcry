Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): n/a.

| bench | base | var | var_env |
|---|---:|---|---|
| JsonGenerate | 3.240 s, 774 MiB | 100% [99, 101] / 1.00× [1.00, 1.00] | 100% [99, 102] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | -2.3% [-2.7%, -1.5%] | -0.3% [-1.4%, +0.8%] | -0.2% [-1.4%, +1.6%] | +4.8% [-12.1%, +24.6%] | -0.4% [-0.6%, -0.3%] | -0.1% [-0.1%, +0.0%] | +11.2% [+7.6%, +12.9%] | +0.0% [+0.0%, +0.0%] | +1.8% [+0.8%, +2.5%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | base | 1.319 | 3.240 | 3.281 | 0.305 | 332166 | 13 | +2.4% [+1.5%, +2.8%] |
| JsonGenerate | var | 1.288 | 3.228 | 3.281 | 0.328 | 330494 | 13 | — |
| JsonGenerate | var_env | 1.290 | 3.231 | 3.312 | 0.281 | 330492 | 13 | +0.1% [-0.5%, +0.7%] |
