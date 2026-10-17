Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): n/a.

| bench | base | var |
|---|---:|---|
| Primes | 1.553 s, 621 MiB | 97% [95, 98] / 0.99× [0.99, 0.99] |
| Revcomp | 3.892 s, 575 MiB | 97% [97, 98] / 0.95× [0.95, 0.95] |
| Brainfuck | 5.274 s, 9 MiB | 97% [95, 100] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | +3.4% [+2.5%, +4.8%] | +3.2% [+2.3%, +4.7%] | -1.1% [-1.4%, -1.0%] | +26.5% [+21.4%, +32.5%] | +0.0% [+0.0%, +0.0%] |
| Revcomp | +8.8% [+8.0%, +9.6%] | +2.8% [+2.4%, +3.6%] | -4.8% [-4.8%, -4.8%] | -7.4% [-10.0%, -3.2%] | -4.3% [-4.3%, -4.3%] |
| Brainfuck | +0.5% [-0.1%, +4.8%] | +2.8% [+0.4%, +4.9%] | +0.2% [+0.0%, +0.4%] | +12.9% [+1.5%, +18.2%] | +0.0% [+0.0%, +0.0%] |
