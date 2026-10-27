Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.3 MiB.

| bench | boehm | base | var |
|---|---:|---|---|
| Binarytrees | 0.694 s, 50 MiB | 103% [101, 104] / 0.74× [0.73, 0.74] | 103% [101, 106] / 0.74× [0.74, 0.74] |
| JsonParsePure | 1.082 s, 692 MiB | 89% [85, 91] / 0.81× [0.80, 0.81] | 89% [86, 89] / 0.81× [0.80, 0.81] |
| Knuckeotide | 0.816 s, 43 MiB | 89% [88, 91] / 1.35× [1.30, 1.44] | 88% [87, 90] / 1.41× [1.31, 1.56] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | +1.5% [-2.6%, +2.5%] | +1.2% [-2.7%, +2.6%] | +0.4% [-1.8%, +2.3%] | +8.7% [-18.3%, +26.3%] | +6.7% [-19.7%, +36.8%] | +0.1% [-0.1%, +0.3%] | +6.5% [-4.2%, +69.8%] | +0.0% [-5.7%, +3.8%] | +8.8% [-2.9%, +52.7%] |
| JsonParsePure | +0.7% [-0.9%, +2.9%] | -0.1% [-1.4%, +2.4%] | +0.6% [-1.1%, +2.1%] | +1.2% [-6.5%, +6.5%] | +0.3% [-0.2%, +1.9%] | -0.1% [-0.3%, +0.1%] | -0.1% [-4.5%, +3.0%] | +0.0% [+0.0%, +0.0%] | +0.4% [-0.4%, +1.5%] |
| Knuckeotide | +2.0% [-0.9%, +3.4%] | +2.0% [-0.8%, +2.9%] | +1.6% [-1.2%, +2.3%] | +2.5% [-9.6%, +7.9%] | +3.2% [-0.9%, +7.7%] | +2.6% [-1.0%, +8.8%] | -3.0% [-6.6%, +0.8%] | +0.0% [-1.5%, +0.0%] | +0.0% [-6.9%, +0.0%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | base | 0.666 | 0.672 | 0.638 | 0.036 | 23316 | 217 | -1.5% [-2.4%, +2.7%] |
| Binarytrees | var | 0.668 | 0.675 | 0.635 | 0.040 | 24882 | 215 | — |
| Binarytrees | boehm | 0.688 | 0.694 | 0.703 | 0.023 | 6049 | n/a | +2.7% [+0.7%, +6.5%] |
| JsonParsePure | base | 0.529 | 1.225 | 1.116 | 0.283 | 196847 | 14 | -0.7% [-2.9%, +0.9%] |
| JsonParsePure | var | 0.535 | 1.225 | 1.127 | 0.288 | 199784 | 14 | — |
| JsonParsePure | boehm | 0.437 | 1.082 | 1.597 | 0.076 | 29734 | n/a | -18.6% [-19.6%, -17.8%] |
| Knuckeotide | base | 0.818 | 0.908 | 0.868 | 0.044 | 29141 | 68 | -1.9% [-3.3%, +0.9%] |
| Knuckeotide | var | 0.833 | 0.922 | 0.879 | 0.043 | 29168 | 68 | — |
| Knuckeotide | boehm | 0.735 | 0.816 | 0.823 | 0.015 | 3096 | n/a | -11.8% [-12.8%, -10.0%] |
