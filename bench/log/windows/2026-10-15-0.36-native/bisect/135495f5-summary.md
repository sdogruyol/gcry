Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): n/a.

| bench | base | var |
|---|---:|---|
| Primes | 1.714 s, 615 MiB | 98% [90, 102] / 1.00× [1.00, 1.00] |
| Revcomp | 3.835 s, 548 MiB | 96% [95, 96] / 1.00× [1.00, 1.00] |
| Brainfuck | 5.325 s, 9 MiB | 100% [93, 102] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | +3.8% [-1.5%, +9.8%] | +2.2% [-2.2%, +11.0%] | -0.1% [-0.1%, +0.1%] | +0.4% [-12.4%, +7.5%] | +0.0% [+0.0%, +0.0%] |
| Revcomp | +13.2% [+12.4%, +14.7%] | +4.5% [+3.8%, +5.6%] | -0.0% [-0.0%, -0.0%] | -4.6% [-8.2%, -0.7%] | +0.0% [+0.0%, +0.0%] |
| Brainfuck | -0.8% [-1.9%, +8.4%] | -0.3% [-2.3%, +7.8%] | +0.1% [-0.2%, +0.2%] | +0.3% [-10.6%, +6.6%] | +0.0% [+0.0%, +0.0%] |
