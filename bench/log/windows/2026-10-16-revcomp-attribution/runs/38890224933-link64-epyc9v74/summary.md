Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): n/a.

| bench | base | var |
|---|---:|---|
| Revcomp | 3.405 s, 548 MiB | 100% [98, 100] / 1.00× [1.00, 1.00] |
| Brainfuck | 4.432 s, 9 MiB | 99% [96, 100] / 1.00× [1.00, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Revcomp | -0.4% [-1.0%, +0.5%] | +0.2% [-0.5%, +1.6%] | +0.0% [-1.9%, +1.7%] | +18.2% [-17.7%, +31.7%] | +0.0% [-0.0%, +0.0%] | +0.0% [-0.0%, +0.0%] | +1.8% [-1.8%, +4.3%] | +0.0% [+0.0%, +0.0%] | +0.0% [+0.0%, +0.0%] |
| Brainfuck | -0.1% [-0.5%, +0.7%] | +1.0% [+0.0%, +3.9%] | +0.0% [-0.7%, +0.7%] | +0.0% [-33.3%, +100.0%] | -0.1% [-3.2%, +0.1%] | +0.0% [-0.2%, +0.1%] | -0.4% [-2.7%, +2.2%] | +0.0% [+0.0%, +0.0%] | +0.0% [+0.0%, +0.0%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Revcomp | base | 1.202 | 3.405 | 3.203 | 0.172 | 346567 | 22 | +0.4% [-0.5%, +1.1%] |
| Revcomp | var | 1.198 | 3.399 | 3.219 | 0.203 | 346435 | 22 | — |
| Brainfuck | base | 4.395 | 4.432 | 4.391 | 0.031 | 2552 | 3 | +0.1% [-0.7%, +0.5%] |
| Brainfuck | var | 4.393 | 4.524 | 4.391 | 0.031 | 2403 | 3 | — |
