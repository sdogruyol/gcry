Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.5 MiB.

| bench | base | var | prepad16 | prepad64 | baseprepad16 | baseprepad64 |
|---|---:|---|---|---|---|---|
| Binarytrees | 1.960 s, 35 MiB | 94% [93, 98] / 1.00× [1.00, 1.00] | 95% [93, 98] / 1.00× [1.00, 1.00] | 94% [91, 97] / 1.00× [1.00, 1.00] | 97% [91, 98] / 1.00× [1.00, 1.00] | 100% [97, 105] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | +6.0% [+1.8%, +7.4%] | +5.8% [+1.9%, +7.6%] | +5.9% [+1.9%, +7.2%] | +3.6% [+1.8%, +5.1%] | -5.3% [-12.0%, +0.4%] | -0.1% [-0.1%, -0.0%] | +4.2% [-17.4%, +31.6%] | +4.1% [+2.6%, +5.6%] | +7.4% [-10.9%, +28.3%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | base | 1.934 | 1.960 | 1.863 | 0.116 | 15765 | 196 | -5.6% [-6.9%, -1.8%] |
| Binarytrees | var | 2.028 | 2.052 | 1.955 | 0.120 | 14671 | 204 | — |
| Binarytrees | prepad16 | 2.033 | 2.056 | 1.956 | 0.122 | 15009 | 203 | -0.1% [-3.8%, +4.4%] |
| Binarytrees | prepad64 | 2.049 | 2.072 | 1.969 | 0.121 | 15408 | 204 | +0.8% [-1.4%, +6.9%] |
| Binarytrees | baseprepad16 | 2.001 | 2.024 | 1.923 | 0.123 | 15425 | 199 | -2.4% [-7.4%, +5.3%] |
| Binarytrees | baseprepad64 | 1.903 | 1.927 | 1.833 | 0.115 | 15285 | 192 | -6.1% [-7.2%, -3.9%] |
