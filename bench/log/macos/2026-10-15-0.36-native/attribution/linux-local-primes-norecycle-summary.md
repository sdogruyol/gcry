Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.5 MiB.

| bench | base | var | var_env |
|---|---:|---|---|
| Primes | 0.689 s, 611 MiB | 103% [100, 104] / 1.00× [1.00, 1.01] | 100% [99, 103] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|
| Primes | -3.0% [-4.7%, +0.0%] | -2.6% [-4.2%, +0.3%] | +0.3% [-0.0%, +0.7%] | -21.9% [-27.0%, -15.8%] | -11.1% [-11.1%, -11.1%] | -33.3% [-37.5%, -29.2%] |
