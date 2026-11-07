Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.5 MiB.

| bench | base | var | prepad16 | prepad64 | baseprepad16 | baseprepad64 |
|---|---:|---|---|---|---|---|
| Binarytrees | 2.288 s, 35 MiB | 104% [88, 107] / 1.00× [1.00, 1.00] | 101% [95, 107] / 1.00× [1.00, 1.00] | 97% [91, 104] / 1.00× [1.00, 1.00] | 101% [96, 110] / 1.00× [1.00, 1.00] | 105% [99, 111] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | -4.1% [-6.8%, +13.3%] | -3.9% [-6.8%, +13.5%] | -4.2% [-6.8%, +12.9%] | +2.2% [-6.9%, +14.7%] | +1.8% [-8.6%, +13.6%] | -0.0% [-0.0%, +0.0%] | +6.1% [-14.4%, +17.0%] | +0.0% [-1.4%, +1.9%] | +0.4% [-5.5%, +8.3%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | base | 2.264 | 2.288 | 2.183 | 0.129 | 15061 | 205 | +4.3% [-11.8%, +7.3%] |
| Binarytrees | var | 2.287 | 2.312 | 2.203 | 0.132 | 15643 | 205 | — |
| Binarytrees | prepad16 | 2.295 | 2.316 | 2.204 | 0.131 | 15452 | 205 | -1.0% [-6.4%, +6.0%] |
| Binarytrees | prepad64 | 2.312 | 2.335 | 2.225 | 0.132 | 15373 | 206 | +0.3% [-3.3%, +8.6%] |
| Binarytrees | baseprepad16 | 2.270 | 2.291 | 2.190 | 0.129 | 15300 | 202 | -1.0% [-7.3%, +3.3%] |
| Binarytrees | baseprepad64 | 2.155 | 2.182 | 2.074 | 0.128 | 16194 | 200 | -5.3% [-8.5%, +0.4%] |
