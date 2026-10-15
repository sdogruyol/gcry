Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | base | var |
|---|---:|---|
| Primes | 1.563 s, 611 MiB | 99% [76, 116] / 1.00× [1.00, 1.01] |
| Revcomp | 4.241 s, 526 MiB | 98% [90, 101] / 1.00× [1.00, 1.00] |
| Brainfuck | 6.037 s, 5 MiB | 98% [92, 102] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | +3.0% [-14.6%, +33.7%] | +1.4% [-14.0%, +31.7%] | +0.1% [-0.4%, +0.6%] | -0.5% [-19.2%, +36.4%] | +0.0% [+0.0%, +0.0%] |
| Revcomp | +4.2% [-2.4%, +8.2%] | +1.7% [-1.0%, +10.7%] | -0.0% [-0.0%, -0.0%] | -4.1% [-14.0%, +16.6%] | +0.0% [+0.0%, +0.0%] |
| Brainfuck | +2.1% [-1.6%, +8.5%] | +2.0% [-1.5%, +8.6%] | +0.0% [+0.0%, +0.1%] | +24.3% [-10.0%, +62.1%] | +0.0% [+0.0%, +0.0%] |
