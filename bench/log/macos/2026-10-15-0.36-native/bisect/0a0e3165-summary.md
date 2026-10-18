Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | base | var |
|---|---:|---|
| Primes | 1.674 s, 614 MiB | 103% [93, 115] / 0.99× [0.99, 1.00] |
| Revcomp | 3.954 s, 583 MiB | 97% [93, 109] / 0.90× [0.89, 0.94] |
| Brainfuck | 5.883 s, 5 MiB | 102% [92, 107] / 1.01× [1.01, 1.01] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | -2.9% [-12.6%, +7.4%] | -2.6% [-12.8%, +7.1%] | -0.9% [-1.1%, +0.2%] | +1.7% [-34.5%, +14.6%] | +0.0% [-11.1%, +0.0%] |
| Revcomp | +4.5% [-9.1%, +14.6%] | +3.6% [-8.2%, +7.0%] | -9.8% [-10.5%, -6.1%] | -4.5% [-9.7%, +12.7%] | +0.0% [-4.5%, +0.0%] |
| Brainfuck | -1.9% [-6.3%, +8.9%] | -1.9% [-6.3%, +8.6%] | +0.7% [+0.6%, +0.8%] | -16.9% [-23.2%, +30.5%] | +0.0% [+0.0%, +0.0%] |
