Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): n/a.

| bench | base | var |
|---|---:|---|
| Primes | 1.393 s, 615 MiB | 98% [95, 104] / 1.00× [1.00, 1.00] |
| Revcomp | 3.268 s, 548 MiB | 97% [97, 98] / 1.00× [1.00, 1.00] |
| Brainfuck | 4.522 s, 9 MiB | 101% [98, 105] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | -1.6% [-3.8%, +4.3%] | +1.7% [-4.0%, +4.8%] | -0.1% [-0.2%, -0.0%] | +0.4% [-2.9%, +3.2%] | +0.0% [+0.0%, +0.0%] |
| Revcomp | +12.4% [+11.0%, +12.6%] | +3.0% [+2.4%, +3.2%] | -0.0% [-0.0%, +0.0%] | +0.2% [-2.9%, +1.9%] | +0.0% [+0.0%, +0.0%] |
| Brainfuck | -0.5% [-2.5%, +1.9%] | -1.3% [-4.7%, +1.7%] | +0.0% [-0.1%, +0.1%] | +5.4% [+2.4%, +7.1%] | +0.0% [+0.0%, +0.0%] |
