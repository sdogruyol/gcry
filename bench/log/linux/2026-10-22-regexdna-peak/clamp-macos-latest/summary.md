Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | boehm | base | var |
|---|---:|---|---|
| Binarytrees | 1.052 s, 39 MiB | 98% [91, 101] / 0.94× [0.94, 0.94] | 93% [85, 100] / 0.94× [0.94, 0.94] |
| JsonParsePure | 1.766 s, 518 MiB | 106% [101, 115] / 0.92× [0.91, 0.93] | 106% [99, 113] / 0.94× [0.92, 0.94] |
| Knuckeotide | 1.479 s, 47 MiB | 91% [85, 97] / 1.32× [1.28, 1.43] | 89% [83, 93] / 1.32× [1.31, 1.58] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | +3.9% [-3.7%, +9.8%] | +3.8% [-3.3%, +9.8%] | +2.1% [-3.0%, +6.8%] | +1.0% [-8.8%, +19.8%] | +12.0% [+3.2%, +33.1%] | +0.0% [-0.0%, +0.0%] | +30.4% [-0.7%, +61.8%] | +0.0% [-4.2%, +2.7%] | +22.9% [+0.3%, +44.6%] |
| JsonParsePure | +1.8% [-8.7%, +15.9%] | +1.7% [-3.6%, +6.8%] | +0.5% [-1.7%, +7.0%] | +16.8% [-1.0%, +32.7%] | +0.5% [-0.6%, +1.3%] | +1.2% [+0.2%, +2.7%] | -2.4% [-9.5%, +7.4%] | -6.7% [-6.7%, +0.0%] | -7.5% [-10.5%, -2.0%] |
| Knuckeotide | +9.1% [-3.2%, +15.0%] | +5.9% [-3.2%, +14.7%] | +6.2% [-4.0%, +12.8%] | +6.6% [-1.2%, +15.9%] | -0.2% [-7.1%, +5.0%] | +0.1% [-0.0%, +2.2%] | +11.0% [+1.4%, +16.0%] | +0.0% [-1.4%, +0.0%] | +0.0% [-5.4%, +1.4%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Binarytrees | base | 1.057 | 1.066 | 0.989 | 0.059 | 4525 | 175 | -3.8% [-8.9%, +3.8%] |
| Binarytrees | var | 1.131 | 1.138 | 1.057 | 0.059 | 5527 | 173 | — |
| Binarytrees | boehm | 1.045 | 1.052 | 1.016 | 0.033 | 2715 | n/a | -7.2% [-15.0%, +0.4%] |
| JsonParsePure | base | 0.799 | 1.725 | 1.735 | 0.157 | 51848 | 15 | -1.7% [-13.7%, +9.5%] |
| JsonParsePure | var | 0.787 | 1.715 | 1.688 | 0.181 | 51813 | 14 | — |
| JsonParsePure | boehm | 0.789 | 1.766 | 1.868 | 0.146 | 33334 | n/a | +1.9% [-4.5%, +13.2%] |
| Knuckeotide | base | 1.549 | 1.666 | 1.580 | 0.058 | 7654 | 70 | -8.3% [-13.0%, +3.3%] |
| Knuckeotide | var | 1.558 | 1.663 | 1.574 | 0.059 | 7916 | 70 | — |
| Knuckeotide | boehm | 1.368 | 1.479 | 1.382 | 0.031 | 3570 | n/a | -13.0% [-18.5%, -8.0%] |
