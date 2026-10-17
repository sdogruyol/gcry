Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | base | var |
|---|---:|---|
| Primes | 0.905 s, 617 MiB | 95% [91, 97] / 0.99× [0.99, 0.99] |
| Revcomp | 3.186 s, 572 MiB | 102% [100, 104] / 0.92× [0.89, 1.00] |
| Brainfuck | 4.366 s, 5 MiB | 99% [95, 103] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | +5.5% [+3.4%, +9.5%] | +5.5% [+3.3%, +9.3%] | -1.3% [-1.5%, -1.2%] | +35.0% [+28.2%, +43.6%] | +0.0% [+0.0%, +0.0%] |
| Revcomp | -5.0% [-8.0%, +2.9%] | -1.7% [-3.7%, +0.1%] | -8.1% [-10.5%, +0.0%] | -7.8% [-10.6%, +1.9%] | +0.0% [+0.0%, +0.0%] |
| Brainfuck | +0.8% [-2.5%, +5.4%] | +0.8% [-2.5%, +5.4%] | -0.3% [-0.3%, -0.2%] | +8.7% [-2.0%, +19.1%] | +0.0% [+0.0%, +0.0%] |
