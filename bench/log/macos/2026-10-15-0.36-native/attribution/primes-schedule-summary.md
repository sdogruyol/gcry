Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | base | var | var_env |
|---|---:|---|---|
| Primes | 1.552 s, 610 MiB | 103% [92, 120] / 1.01× [1.00, 1.01] | 108% [87, 116] / 1.00× [0.99, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|
| Primes | -2.3% [-17.0%, +8.9%] | -2.3% [-16.9%, +8.8%] | +0.5% [+0.4%, +0.5%] | -20.0% [-34.7%, -15.5%] | -11.1% [-11.1%, -2.8%] | -35.0% [-41.9%, -9.3%] |
