Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.5 MiB.

| bench | base | var | prepad16 | prepad64 | baseprepad16 | baseprepad64 |
|---|---:|---|---|---|---|---|
| Binarytrees | 1.462 s, 35 MiB | 96% [93, 102] / 1.00× [1.00, 1.00] | 100% [96, 106] / 1.00× [1.00, 1.00] | 95% [91, 100] / 1.00× [1.00, 1.00] | 97% [95, 103] / 1.00× [1.00, 1.00] | 101% [96, 111] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | +4.6% [-1.5%, +7.7%] | +4.6% [-1.7%, +7.6%] | +4.6% [-1.5%, +7.7%] | -1.6% [-12.6%, +6.3%] | -2.0% [-12.2%, -0.8%] | -0.1% [-0.1%, -0.1%] | -2.8% [-8.7%, +25.1%] | +5.9% [+2.1%, +7.4%] | +3.7% [-2.5%, +38.9%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | base | 1.446 | 1.462 | 1.384 | 0.090 | 16250 | 187 | -4.4% [-7.2%, +1.5%] |
| Binarytrees | var | 1.511 | 1.529 | 1.449 | 0.090 | 15689 | 197 | — |
| Binarytrees | prepad16 | 1.429 | 1.446 | 1.370 | 0.083 | 15397 | 199 | -2.8% [-6.9%, +1.5%] |
| Binarytrees | prepad64 | 1.508 | 1.525 | 1.453 | 0.085 | 15636 | 200 | +1.6% [-2.8%, +5.9%] |
| Binarytrees | baseprepad16 | 1.445 | 1.461 | 1.385 | 0.088 | 15563 | 193 | -3.0% [-4.2%, +3.8%] |
| Binarytrees | baseprepad64 | 1.404 | 1.422 | 1.345 | 0.083 | 16020 | 188 | -4.3% [-9.9%, -0.7%] |
