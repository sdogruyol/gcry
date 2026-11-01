Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.5 MiB.

| bench | base | var | prepad16 | prepad64 | baseprepad16 | baseprepad64 |
|---|---:|---|---|---|---|---|
| Binarytrees | 1.339 s, 35 MiB | 97% [94, 103] / 1.00× [1.00, 1.00] | 97% [93, 101] / 1.00× [1.00, 1.00] | 98% [95, 100] / 1.00× [1.00, 1.00] | 98% [95, 102] / 1.00× [1.00, 1.00] | 102% [100, 107] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | +3.6% [-2.6%, +6.3%] | +3.6% [-2.7%, +6.3%] | +3.7% [-4.0%, +5.9%] | -2.8% [-7.9%, +10.6%] | -4.3% [-8.7%, +7.9%] | -0.1% [-0.1%, -0.0%] | -4.0% [-20.7%, +14.8%] | +6.3% [+3.7%, +9.1%] | +0.5% [-12.7%, +18.5%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | base | 1.323 | 1.339 | 1.275 | 0.073 | 16062 | 187 | -3.5% [-6.0%, +2.7%] |
| Binarytrees | var | 1.378 | 1.398 | 1.335 | 0.078 | 15496 | 200 | — |
| Binarytrees | prepad16 | 1.427 | 1.443 | 1.373 | 0.081 | 15367 | 194 | +1.4% [-1.0%, +7.9%] |
| Binarytrees | prepad64 | 1.367 | 1.383 | 1.315 | 0.080 | 16364 | 192 | -1.8% [-3.9%, +4.6%] |
| Binarytrees | baseprepad16 | 1.358 | 1.374 | 1.308 | 0.080 | 15254 | 192 | -2.9% [-4.5%, +2.5%] |
| Binarytrees | baseprepad64 | 1.295 | 1.311 | 1.240 | 0.076 | 14896 | 186 | -5.5% [-9.0%, -4.0%] |
