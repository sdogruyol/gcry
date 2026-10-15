Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): n/a.

| bench | base | var | var_env |
|---|---:|---|---|
| Primes | 1.364 s, 622 MiB | 97% [95, 99] / 0.99× [0.99, 0.99] | 99% [94, 101] / 1.00× [1.00, 1.00] |
| JsonParseSerializable | 1.856 s, 519 MiB | 101% [95, 108] / 0.86× [0.85, 0.87] | 98% [96, 103] / 1.00× [0.98, 1.00] |
| JsonGenerate | 3.093 s, 932 MiB | 100% [97, 103] / 0.83× [0.83, 0.83] | 97% [93, 98] / 0.92× [0.92, 0.92] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|
| Primes | +2.9% [+1.3%, +4.2%] | +2.9% [+1.2%, +5.6%] | -1.2% [-1.4%, -1.1%] | +26.3% [+19.0%, +31.0%] | +0.0% [+0.0%, +0.0%] | +19.7% [+15.5%, +21.7%] |
| JsonParseSerializable | +2.9% [+1.6%, +4.7%] | -1.0% [-7.1%, +4.8%] | -13.7% [-14.8%, -12.8%] | -15.8% [-18.6%, -10.4%] | -14.3% [-14.3%, -14.3%] | -16.7% [-18.8%, -12.6%] |
| JsonGenerate | +6.5% [+4.6%, +7.2%] | +0.1% [-2.6%, +2.8%] | -17.0% [-17.0%, -16.9%] | -5.8% [-6.5%, -5.0%] | -7.1% [-7.1%, -7.1%] | -6.1% [-7.8%, -5.7%] |
