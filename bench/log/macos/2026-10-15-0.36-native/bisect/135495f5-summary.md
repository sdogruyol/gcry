Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | base | var |
|---|---:|---|
| Primes | 1.689 s, 610 MiB | 100% [92, 114] / 1.00× [0.99, 1.01] |
| Revcomp | 4.426 s, 526 MiB | 102% [95, 112] / 1.00× [1.00, 1.00] |
| Brainfuck | 6.021 s, 5 MiB | 98% [90, 107] / 1.00× [1.00, 1.01] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | -0.5% [-11.6%, +8.2%] | -0.4% [-11.9%, +8.2%] | -0.0% [-0.8%, +0.5%] | -1.4% [-11.8%, +14.7%] | +0.0% [+0.0%, +0.0%] |
| Revcomp | -3.3% [-15.6%, +12.6%] | -1.9% [-11.1%, +4.8%] | +0.0% [-0.0%, +0.0%] | -8.8% [-23.0%, +15.3%] | +0.0% [+0.0%, +0.0%] |
| Brainfuck | +1.7% [-6.9%, +10.8%] | +1.7% [-6.9%, +10.8%] | +0.3% [+0.3%, +0.7%] | +6.0% [-12.6%, +28.1%] | +0.0% [+0.0%, +0.0%] |
