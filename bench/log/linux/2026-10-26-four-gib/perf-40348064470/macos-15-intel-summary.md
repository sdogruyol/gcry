Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.5 MiB.

| bench | base | var | var_env |
|---|---:|---|---|
| JsonGenerate | 5.814 s, 872 MiB | 101% [96, 109] / 1.00× [0.90, 1.03] | 105% [100, 112] / 1.00× [0.91, 1.07] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | -4.9% [-9.9%, -0.5%] | -0.9% [-8.4%, +4.7%] | -2.8% [-12.2%, +4.1%] | +5.4% [-6.3%, +14.6%] | -0.3% [-0.6%, +0.2%] | -0.0% [-10.2%, +3.1%] | -5.2% [-16.5%, +7.4%] | +0.0% [+0.0%, +0.0%] | +0.6% [-2.0%, +7.7%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | base | 2.447 | 5.814 | 5.733 | 0.657 | 329011 | 14 | +5.2% [+0.5%, +11.1%] |
| JsonGenerate | var | 2.388 | 5.583 | 5.489 | 0.700 | 328345 | 14 | — |
| JsonGenerate | var_env | 2.389 | 5.551 | 5.462 | 0.648 | 328132 | 14 | -2.1% [-9.8%, +12.1%] |
