Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.5 MiB.

| bench | base | var | prepad16 | prepad64 | baseprepad16 | baseprepad64 |
|---|---:|---|---|---|---|---|
| Binarytrees | 1.421 s, 35 MiB | 96% [94, 100] / 1.00× [1.00, 1.00] | 97% [94, 100] / 1.00× [1.00, 1.00] | 96% [93, 99] / 1.00× [1.00, 1.00] | 101% [100, 102] / 1.00× [1.00, 1.00] | 102% [100, 104] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | +4.1% [+0.2%, +6.2%] | +4.0% [+0.2%, +6.0%] | +4.2% [+0.2%, +6.1%] | +0.9% [-2.9%, +2.9%] | -3.2% [-5.6%, +1.2%] | -0.1% [-0.1%, -0.1%] | +0.2% [-11.5%, +13.6%] | +3.0% [+1.5%, +5.3%] | +5.8% [-5.5%, +16.6%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | base | 1.406 | 1.421 | 1.352 | 0.073 | 15232 | 197 | -4.0% [-5.8%, -0.2%] |
| Binarytrees | var | 1.442 | 1.457 | 1.396 | 0.074 | 14901 | 203 | — |
| Binarytrees | prepad16 | 1.456 | 1.471 | 1.404 | 0.075 | 15240 | 202 | -0.1% [-2.3%, +2.5%] |
| Binarytrees | prepad64 | 1.459 | 1.474 | 1.412 | 0.073 | 15475 | 206 | +1.0% [-0.4%, +2.7%] |
| Binarytrees | baseprepad16 | 1.396 | 1.412 | 1.349 | 0.070 | 14590 | 203 | -4.2% [-5.8%, -1.3%] |
| Binarytrees | baseprepad64 | 1.373 | 1.389 | 1.326 | 0.072 | 15264 | 192 | -4.9% [-6.1%, -2.8%] |
