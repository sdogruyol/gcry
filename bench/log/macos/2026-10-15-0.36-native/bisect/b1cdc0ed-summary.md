Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | base | var |
|---|---:|---|
| Primes | 1.647 s, 612 MiB | 106% [94, 118] / 1.00× [1.00, 1.01] |
| Revcomp | 4.214 s, 526 MiB | 108% [100, 111] / 1.00× [1.00, 1.00] |
| Brainfuck | 6.024 s, 5 MiB | 102% [98, 107] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | -5.8% [-16.2%, +6.4%] | -5.2% [-15.5%, +5.8%] | +0.1% [-0.3%, +0.6%] | +6.9% [-6.6%, +19.3%] | +0.0% [+0.0%, +0.0%] |
| Revcomp | -6.6% [-14.3%, +1.1%] | -7.0% [-10.1%, +0.4%] | +0.0% [-0.0%, +0.0%] | -9.5% [-13.9%, +7.3%] | +0.0% [+0.0%, +0.0%] |
| Brainfuck | -2.2% [-6.3%, +2.2%] | -2.1% [-6.5%, +2.3%] | +0.0% [-0.3%, +0.1%] | -9.3% [-26.1%, +23.5%] | +0.0% [+0.0%, +0.0%] |
