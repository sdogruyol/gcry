Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): n/a.

| bench | base | var | var_env |
|---|---:|---|---|
| Primes | 1.490 s, 622 MiB | 96% [94, 99] / 0.99× [0.99, 0.99] | 100% [97, 102] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|
| Primes | +1.7% [-0.1%, +5.4%] | +4.5% [+0.6%, +6.5%] | -1.1% [-1.2%, -0.9%] | +25.6% [+24.2%, +27.7%] | +0.0% [+0.0%, +0.0%] | +17.5% [+15.2%, +19.1%] |
