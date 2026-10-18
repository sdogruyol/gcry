Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | base | var |
|---|---:|---|
| Primes | 1.525 s, 614 MiB | 103% [93, 110] / 0.99× [0.99, 0.99] |
| Revcomp | 4.157 s, 588 MiB | 105% [92, 108] / 0.91× [0.89, 1.00] |
| Brainfuck | 6.336 s, 5 MiB | 103% [100, 110] / 1.01× [1.00, 1.01] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | -3.2% [-9.7%, +7.5%] | -2.8% [-9.5%, +7.8%] | -0.7% [-1.1%, -0.6%] | +5.7% [-14.8%, +27.7%] | +0.0% [-11.1%, +0.0%] |
| Revcomp | -0.9% [-6.5%, +2.3%] | -4.4% [-7.3%, +8.2%] | -9.3% [-10.5%, +0.0%] | -5.4% [-10.5%, +2.3%] | +0.0% [+0.0%, +0.0%] |
| Brainfuck | -3.1% [-9.5%, +0.2%] | -3.1% [-9.4%, +0.2%] | +0.7% [+0.3%, +0.7%] | -3.5% [-27.5%, +12.4%] | +0.0% [+0.0%, +0.0%] |
