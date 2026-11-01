Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.5 MiB.

| bench | base | var | prepad16 | prepad64 | baseprepad16 | baseprepad64 |
|---|---:|---|---|---|---|---|
| Binarytrees | 1.677 s, 35 MiB | 95% [94, 96] / 1.00× [1.00, 1.00] | 95% [94, 97] / 1.00× [1.00, 1.00] | 97% [95, 99] / 1.00× [1.00, 1.00] | 98% [96, 100] / 1.00× [1.00, 1.00] | 100% [97, 101] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | +5.7% [+4.1%, +7.0%] | +5.6% [+4.0%, +6.9%] | +5.6% [+4.0%, +7.6%] | +3.2% [+0.3%, +6.1%] | +2.6% [-0.7%, +6.4%] | -0.1% [-0.1%, -0.0%] | +3.8% [-6.9%, +18.2%] | +3.6% [+1.5%, +4.5%] | +6.1% [-6.9%, +19.0%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | base | 1.657 | 1.677 | 1.603 | 0.087 | 14209 | 201 | -5.4% [-6.5%, -3.9%] |
| Binarytrees | var | 1.746 | 1.765 | 1.691 | 0.090 | 14791 | 208 | — |
| Binarytrees | prepad16 | 1.739 | 1.759 | 1.682 | 0.090 | 15067 | 205 | -1.3% [-2.2%, +0.8%] |
| Binarytrees | prepad64 | 1.713 | 1.732 | 1.659 | 0.088 | 14875 | 205 | -2.2% [-3.8%, +1.1%] |
| Binarytrees | baseprepad16 | 1.685 | 1.705 | 1.631 | 0.087 | 14797 | 206 | -4.1% [-4.8%, -0.8%] |
| Binarytrees | baseprepad64 | 1.668 | 1.688 | 1.609 | 0.088 | 15182 | 200 | -5.6% [-7.1%, -3.3%] |
