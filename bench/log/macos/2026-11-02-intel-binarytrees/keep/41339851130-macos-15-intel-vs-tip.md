Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.5 MiB.

| bench | base | var | prepad16 | prepad64 | baseprepad16 | baseprepad64 |
|---|---:|---|---|---|---|---|
| JsonGenerate | 4.564 s, 770 MiB | 101% [99, 103] / 1.00× [1.00, 1.00] | 100% [99, 102] / 1.00× [1.00, 1.00] | 100% [99, 102] / 1.00× [1.00, 1.00] | 102% [99, 105] / 1.00× [1.00, 1.00] | 102% [100, 103] / 1.00× [1.00, 1.00] |
| Binarytrees | 1.522 s, 35 MiB | 106% [104, 112] / 1.00× [1.00, 1.00] | 106% [102, 110] / 1.00× [1.00, 1.00] | 103% [100, 105] / 1.00× [1.00, 1.00] | 100% [98, 105] / 1.00× [1.00, 1.00] | 99% [96, 101] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | +1.6% [-0.5%, +3.6%] | -0.6% [-3.3%, +0.7%] | -0.1% [-3.3%, +0.5%] | -1.2% [-6.1%, +0.9%] | +0.0% [+0.0%, +0.0%] | -0.2% [-0.2%, -0.0%] | -5.9% [-9.1%, -2.8%] | +0.0% [+0.0%, +0.0%] | -2.4% [-2.9%, -0.1%] |
| Binarytrees | -5.9% [-11.1%, -3.9%] | -5.6% [-11.0%, -3.9%] | -5.8% [-11.1%, -3.8%] | -5.9% [-13.7%, +2.6%] | -4.7% [-11.5%, +1.7%] | +0.0% [+0.0%, +0.0%] | -20.2% [-28.1%, +9.6%] | -4.4% [-6.3%, -2.9%] | -20.6% [-24.9%, +1.0%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| JsonGenerate | base | 2.009 | 4.564 | 4.495 | 0.478 | 328195 | 13 | -1.5% [-3.5%, +0.5%] |
| JsonGenerate | var | 2.040 | 4.546 | 4.466 | 0.476 | 328286 | 13 | — |
| JsonGenerate | prepad16 | 2.063 | 4.536 | 4.451 | 0.494 | 328293 | 13 | +1.0% [-0.8%, +3.3%] |
| JsonGenerate | prepad64 | 1.950 | 4.499 | 4.402 | 0.490 | 328201 | 13 | -3.4% [-8.2%, -0.6%] |
| JsonGenerate | baseprepad16 | 1.988 | 4.496 | 4.425 | 0.463 | 328197 | 13 | -1.8% [-5.2%, -0.5%] |
| JsonGenerate | baseprepad64 | 1.949 | 4.491 | 4.405 | 0.492 | 328194 | 13 | -4.6% [-6.0%, -3.1%] |
| Binarytrees | base | 1.507 | 1.522 | 1.460 | 0.072 | 15276 | 206 | +6.2% [+4.1%, +12.5%] |
| Binarytrees | var | 1.427 | 1.444 | 1.383 | 0.070 | 13941 | 197 | — |
| Binarytrees | prepad16 | 1.419 | 1.434 | 1.372 | 0.069 | 14874 | 199 | +0.0% [-1.6%, +3.6%] |
| Binarytrees | prepad64 | 1.476 | 1.492 | 1.434 | 0.072 | 14840 | 205 | +4.2% [+3.3%, +6.1%] |
| Binarytrees | baseprepad16 | 1.484 | 1.501 | 1.441 | 0.071 | 15262 | 207 | +4.3% [+1.4%, +10.0%] |
| Binarytrees | baseprepad64 | 1.507 | 1.525 | 1.461 | 0.072 | 14639 | 212 | +7.0% [+4.0%, +12.2%] |
