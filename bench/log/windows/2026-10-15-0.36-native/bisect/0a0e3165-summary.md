Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): n/a.

| bench | base | var |
|---|---:|---|
| Primes | 1.599 s, 620 MiB | 106% [103, 109] / 0.99× [0.99, 0.99] |
| Revcomp | 4.035 s, 575 MiB | 100% [98, 101] / 0.95× [0.94, 0.95] |
| Brainfuck | 5.319 s, 9 MiB | 100% [100, 102] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | -6.0% [-6.8%, -3.0%] | -5.8% [-8.6%, -3.0%] | -0.9% [-1.1%, -0.6%] | -42.2% [-43.7%, -22.8%] | -11.1% [-11.1%, -8.3%] |
| Revcomp | -3.5% [-4.0%, -2.7%] | -0.2% [-0.6%, +1.8%] | -4.8% [-5.8%, -4.8%] | -9.8% [-11.9%, -5.7%] | -4.3% [-4.3%, -4.3%] |
| Brainfuck | -0.1% [-2.4%, +0.1%] | -0.4% [-2.1%, +0.0%] | -0.1% [-0.1%, +0.1%] | +1.4% [-4.5%, +11.2%] | +0.0% [+0.0%, +0.0%] |
