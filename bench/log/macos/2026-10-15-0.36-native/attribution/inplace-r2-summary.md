Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | base | var | var_env |
|---|---:|---|---|
| Primes | 1.028 s, 618 MiB | 96% [94, 99] / 0.99× [0.99, 0.99] | 100% [95, 104] / 1.00× [1.00, 1.00] |
| JsonParseSerializable | 1.426 s, 515 MiB | 104% [102, 107] / 0.95× [0.95, 0.96] | 101% [97, 105] / 1.00× [0.97, 1.00] |
| JsonGenerate | 2.470 s, 856 MiB | 102% [100, 107] / 0.90× [0.90, 1.08] | 102% [97, 105] / 1.00× [0.99, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|
| Primes | +4.9% [+1.6%, +6.5%] | +4.1% [+1.2%, +6.0%] | -1.2% [-1.3%, -1.1%] | +26.9% [+21.5%, +31.4%] | +0.0% [+0.0%, +0.0%] | +20.9% [+19.7%, +22.4%] |
| JsonParseSerializable | -1.0% [-3.6%, +2.9%] | -3.9% [-6.6%, -1.8%] | -4.7% [-5.2%, -4.1%] | -19.3% [-22.9%, -14.7%] | -15.4% [-15.4%, -15.4%] | -17.8% [-18.5%, -17.4%] |
| JsonGenerate | +0.4% [-1.1%, +2.9%] | -2.1% [-7.0%, +0.3%] | -9.9% [-10.0%, +8.4%] | -7.8% [-12.9%, -3.3%] | -7.7% [-7.7%, -7.7%] | -6.1% [-6.3%, -5.8%] |
