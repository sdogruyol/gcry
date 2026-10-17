Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): n/a.

| bench | base | var |
|---|---:|---|
| Primes | 1.476 s, 615 MiB | 105% [98, 109] / 1.00× [1.00, 1.00] |
| Revcomp | 3.399 s, 575 MiB | 99% [96, 101] / 0.95× [0.95, 0.95] |
| Brainfuck | 4.507 s, 9 MiB | 101% [99, 102] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | -6.3% [-7.5%, -1.3%] | -4.9% [-8.0%, +2.3%] | -0.0% [-0.2%, +0.2%] | -36.5% [-38.5%, -19.4%] | -11.1% [-11.1%, -8.3%] |
| Revcomp | +10.5% [+9.8%, +11.0%] | +1.5% [-1.3%, +3.9%] | -4.8% [-4.8%, -4.8%] | -8.4% [-10.5%, -5.7%] | -4.3% [-4.3%, -4.3%] |
| Brainfuck | +0.3% [-0.5%, +0.9%] | -0.9% [-2.3%, +0.7%] | +0.2% [+0.0%, +0.5%] | +4.7% [+3.6%, +9.0%] | +0.0% [+0.0%, +0.0%] |
