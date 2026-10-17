Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): n/a.

| bench | base | var |
|---|---:|---|
| Primes | 0.908 s, 618 MiB | 100% [93, 107] / 1.00× [1.00, 1.00] |
| JsonParsePure | 1.239 s, 563 MiB | 101% [100, 104] / 0.99× [0.99, 0.99] |
| Binarytrees | 0.917 s, 41 MiB | 99% [94, 107] / 1.00× [1.00, 1.00] |
| JsonGenerate | 2.089 s, 774 MiB | 102% [100, 104] / 1.00× [1.00, 1.15] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|
| Primes | -1.1% [-1.9%, +1.4%] | +0.4% [-6.7%, +8.2%] | -0.1% [-0.1%, +0.2%] | -5.7% [-7.7%, +10.9%] | +0.0% [+0.0%, +0.0%] | +1.1% [-2.0%, +1.8%] |
| JsonParsePure | +0.6% [-1.4%, +1.5%] | -0.7% [-3.4%, +0.4%] | -0.8% [-0.9%, -0.5%] | -3.0% [-8.7%, +1.3%] | +0.0% [+0.0%, +0.0%] | -1.3% [-1.8%, -0.7%] |
| Binarytrees | -0.9% [-2.4%, +1.3%] | +0.7% [-6.8%, +6.8%] | -0.0% [-0.0%, +0.0%] | -18.8% [-31.7%, -2.9%] | +1.4% [-1.4%, +4.0%] | -17.4% [-31.9%, -2.8%] |
| JsonGenerate | -0.4% [-1.8%, +0.9%] | -1.8% [-3.7%, -0.2%] | -0.0% [-0.1%, +15.2%] | -11.5% [-20.6%, -9.2%] | +0.0% [+0.0%, +0.0%] | +0.5% [-0.0%, +0.9%] |
