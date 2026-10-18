Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.5 MiB.

| bench | base | var | var_env |
|---|---:|---|---|
| Primes | 0.731 s, 611 MiB | 104% [102, 107] / 1.01× [1.00, 1.01] | 101% [99, 102] / 1.00× [1.00, 1.01] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | -4.4% [-6.3%, -1.8%] | -3.7% [-6.4%, -1.7%] | +0.5% [+0.3%, +0.7%] | -21.8% [-28.6%, -12.7%] | -11.1% [-11.1%, -11.1%] |
