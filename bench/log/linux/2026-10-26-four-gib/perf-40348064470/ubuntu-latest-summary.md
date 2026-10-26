Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | base | var | var_env |
|---|---:|---|---|
| JsonGenerate | 3.376 s, 771 MiB | 99% [99, 100] / 1.00× [1.00, 1.00] | 99% [98, 100] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | +3.4% [+2.8%, +4.3%] | +0.9% [+0.2%, +1.4%] | +0.5% [-0.5%, +1.8%] | +0.1% [-2.4%, +3.2%] | +0.3% [-0.1%, +0.7%] | +0.0% [-0.0%, +0.0%] | -1.7% [-7.2%, +2.6%] | +7.1% [+0.0%, +7.1%] | +9.0% [+0.2%, +13.2%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | base | 1.361 | 3.376 | 3.185 | 0.563 | 292496 | 14 | -3.3% [-4.1%, -2.7%] |
| JsonGenerate | var | 1.409 | 3.405 | 3.210 | 0.563 | 293015 | 15 | — |
| JsonGenerate | var_env | 1.412 | 3.398 | 3.198 | 0.568 | 292966 | 14 | +0.1% [-0.5%, +0.6%] |
