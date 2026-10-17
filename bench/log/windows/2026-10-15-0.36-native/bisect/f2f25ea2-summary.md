Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): n/a.

| bench | base | var |
|---|---:|---|
| Primes | 1.589 s, 615 MiB | 98% [93, 100] / 1.00× [1.00, 1.00] |
| Revcomp | 3.936 s, 575 MiB | 98% [97, 98] / 0.95× [0.95, 0.95] |
| Brainfuck | 5.670 s, 9 MiB | 101% [96, 111] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | +2.6% [+1.0%, +5.5%] | +2.3% [+0.5%, +7.7%] | +0.0% [-0.1%, +0.2%] | -4.2% [-6.5%, +6.5%] | +0.0% [+0.0%, +0.0%] |
| Revcomp | +7.2% [+5.1%, +7.8%] | +2.4% [+2.0%, +3.2%] | -4.8% [-4.8%, -4.8%] | -4.1% [-6.9%, +1.5%] | +0.0% [+0.0%, +0.0%] |
| Brainfuck | +0.0% [-8.8%, +2.1%] | -1.1% [-10.1%, +3.9%] | +0.2% [+0.0%, +0.4%] | -2.1% [-4.9%, +11.9%] | +0.0% [+0.0%, +0.0%] |
