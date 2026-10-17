Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): n/a.

| bench | base | var | var_env |
|---|---:|---|---|
| Primes | 1.560 s, 622 MiB | 99% [98, 108] / 0.99× [0.99, 0.99] | 99% [97, 105] / 1.00× [1.00, 1.00] |
| Revcomp | 3.949 s, 576 MiB | 97% [95, 99] / 0.95× [0.90, 0.95] | 96% [91, 99] / 0.95× [0.93, 0.95] |
| Brainfuck | 5.836 s, 9 MiB | 104% [98, 112] / 0.95× [0.94, 0.95] | 108% [97, 113] / 0.95× [0.94, 0.95] |
| JsonParseSerializable | 1.999 s, 519 MiB | 101% [99, 107] / 0.86× [0.84, 0.92] | 97% [94, 98] / 1.00× [1.00, 1.02] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections |
|---|---:|---:|---:|---:|---:|
| Primes | +1.2% [-1.6%, +3.3%] | +0.6% [-7.8%, +2.1%] | -1.1% [-1.2%, -1.0%] | +23.1% [+17.7%, +31.8%] | +0.0% [+0.0%, +0.0%] |
| Revcomp | +11.6% [+11.3%, +12.3%] | +2.7% [+1.0%, +5.0%] | -4.9% [-9.5%, -4.9%] | -9.6% [-11.0%, -3.8%] | -4.3% [-4.3%, -4.3%] |
| Brainfuck | -3.1% [-11.1%, +2.3%] | -3.6% [-10.5%, +2.3%] | -5.4% [-5.6%, -5.3%] | +2.1% [+1.0%, +7.0%] | +0.0% [+0.0%, +0.0%] |
| JsonParseSerializable | +0.7% [-1.6%, +2.1%] | -1.1% [-6.2%, +1.0%] | -14.3% [-15.6%, -8.3%] | -19.2% [-20.6%, -17.2%] | -14.3% [-14.3%, -14.3%] |
