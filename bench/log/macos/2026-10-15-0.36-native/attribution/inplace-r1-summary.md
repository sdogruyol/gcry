Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | base | var | var_env |
|---|---:|---|---|
| Primes | 1.270 s, 618 MiB | 95% [88, 98] / 0.99× [0.99, 0.99] | 100% [98, 110] / 1.00× [1.00, 1.00] |
| Revcomp | 3.777 s, 622 MiB | 101% [98, 105] / 0.92× [0.85, 0.94] | 94% [90, 98] / 0.95× [0.92, 1.02] |
| Brainfuck | 5.466 s, 5 MiB | 99% [96, 110] / 0.94× [0.94, 0.94] | 103% [98, 106] / 0.94× [0.94, 0.94] |
| JsonParseSerializable | 1.683 s, 515 MiB | 101% [98, 109] / 0.95× [0.94, 0.96] | 97% [93, 107] / 0.99× [0.97, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | +5.1% [+3.0%, +14.3%] | +5.7% [+2.1%, +13.5%] | -1.3% [-1.5%, -1.3%] | +32.0% [+18.8%, +52.0%] | +0.0% [+0.0%, +0.0%] |
| Revcomp | +0.4% [-3.5%, +4.0%] | -0.9% [-5.0%, +2.5%] | -8.1% [-15.3%, -6.0%] | -4.6% [-14.1%, +2.4%] | -4.5% [-4.5%, -4.5%] |
| Brainfuck | +1.1% [-9.1%, +3.6%] | +0.9% [-9.0%, +3.8%] | -5.8% [-5.8%, -5.5%] | -10.7% [-32.1%, +31.6%] | +0.0% [+0.0%, +0.0%] |
| JsonParseSerializable | -1.5% [-7.2%, +6.7%] | -0.7% [-7.8%, +1.6%] | -4.7% [-6.5%, -3.6%] | -14.3% [-24.4%, +5.6%] | -15.4% [-15.4%, -15.4%] |
