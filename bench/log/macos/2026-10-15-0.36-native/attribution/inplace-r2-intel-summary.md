Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.5 MiB.

| bench | base | var | var_env |
|---|---:|---|---|
| Primes | 2.110 s, 611 MiB | 105% [99, 108] / 0.99× [0.98, 1.00] | 99% [95, 102] / 1.00× [0.98, 1.00] |
| JsonParseSerializable | 3.286 s, 501 MiB | 104% [97, 110] / 0.94× [0.90, 0.96] | 100% [96, 104] / 1.01× [0.97, 1.03] |
| JsonGenerate | 5.041 s, 873 MiB | 103% [101, 109] / 0.90× [0.88, 0.94] | 99% [97, 105] / 1.00× [0.98, 1.01] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|
| Primes | -5.0% [-7.1%, +1.4%] | -4.9% [-7.3%, +1.4%] | -0.6% [-2.0%, -0.0%] | -15.2% [-27.6%, -6.3%] | -11.1% [-11.1%, -11.1%] | -29.1% [-31.4%, -20.6%] |
| JsonParseSerializable | -4.5% [-10.9%, +0.2%] | -3.5% [-8.7%, +2.9%] | -5.9% [-10.0%, -3.5%] | +1.1% [-10.4%, +39.4%] | -14.3% [-14.3%, -14.3%] | -11.1% [-23.2%, +4.5%] |
| JsonGenerate | +1.1% [-4.9%, +3.3%] | -3.0% [-7.9%, -0.9%] | -10.3% [-12.2%, -5.9%] | -2.3% [-5.9%, +9.2%] | -7.1% [-7.1%, -7.1%] | -4.1% [-6.6%, +3.7%] |
