Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | base | var | prepad8 | prepad32 | prepad48 | prepad96 | baseprepad8 | baseprepad32 | baseprepad48 | baseprepad96 |
|---|---:|---|---|---|---|---|---|---|---|---|
| JsonParsePull | 1.969 s, 418 MiB | 99% [98, 99] / 0.98× [0.97, 1.07] | 98% [98, 99] / 1.00× [0.99, 1.01] | 99% [98, 100] / 0.98× [0.97, 1.08] | 100% [99, 100] / 0.99× [0.97, 1.12] | 98% [98, 99] / 1.03× [0.98, 1.12] | 99% [99, 100] / 1.00× [1.00, 1.02] | 100% [99, 101] / 1.00× [1.00, 1.01] | 99% [99, 100] / 0.99× [0.98, 1.00] | 100% [99, 100] / 1.00× [0.99, 1.03] |
| JsonParseSerializable | 1.987 s, 418 MiB | 99% [98, 100] / 0.98× [0.97, 1.11] | 99% [98, 100] / 1.00× [1.00, 1.01] | 99% [98, 99] / 1.04× [0.98, 1.12] | 99% [98, 100] / 1.10× [1.01, 1.12] | 99% [98, 99] / 1.02× [0.98, 1.09] | 99% [98, 100] / 1.00× [0.99, 1.02] | 100% [99, 100] / 1.00× [0.99, 1.07] | 100% [99, 100] / 0.99× [0.98, 0.99] | 100% [99, 101] / 1.00× [0.99, 1.00] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| JsonParsePull | +3.9% [+3.5%, +4.2%] | +1.1% [+0.6%, +2.0%] | +0.6% [-0.6%, +1.1%] | +3.0% [-4.4%, +7.9%] | -1.9% [-2.3%, +4.9%] | -1.6% [-2.8%, +6.6%] | -16.9% [-19.2%, -13.8%] | +0.0% [+0.0%, +7.7%] | -5.4% [-7.3%, -3.3%] |
| JsonParseSerializable | +1.9% [+1.2%, +2.5%] | +1.1% [+0.2%, +2.2%] | +0.5% [-0.5%, +1.5%] | +0.1% [-4.3%, +3.0%] | -1.8% [-2.6%, +6.1%] | -2.1% [-2.8%, +11.2%] | -17.8% [-20.9%, -10.6%] | +0.0% [+0.0%, +0.0%] | -5.7% [-8.4%, -5.2%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| JsonParsePull | base | 0.730 | 1.969 | 1.814 | 0.261 | 133497 | 14 | -3.7% [-4.0%, -3.4%] |
| JsonParsePull | var | 0.760 | 1.992 | 1.822 | 0.268 | 130856 | 14 | — |
| JsonParsePull | prepad8 | 0.752 | 1.993 | 1.837 | 0.262 | 134105 | 15 | -0.9% [-1.2%, -0.6%] |
| JsonParsePull | prepad32 | 0.762 | 1.982 | 1.808 | 0.277 | 132461 | 14 | +0.5% [-0.1%, +0.9%] |
| JsonParsePull | prepad48 | 0.714 | 1.976 | 1.793 | 0.266 | 132044 | 14 | -6.0% [-6.8%, -5.6%] |
| JsonParsePull | prepad96 | 0.766 | 2.004 | 1.814 | 0.277 | 138506 | 14 | +0.8% [+0.1%, +1.4%] |
| JsonParsePull | baseprepad8 | 0.739 | 1.984 | 1.817 | 0.272 | 133891 | 14 | -2.9% [-3.1%, -2.1%] |
| JsonParsePull | baseprepad32 | 0.732 | 1.967 | 1.799 | 0.270 | 133582 | 14 | -3.8% [-4.3%, -3.2%] |
| JsonParsePull | baseprepad48 | 0.706 | 1.984 | 1.819 | 0.264 | 133184 | 13 | -6.8% [-7.2%, -6.7%] |
| JsonParsePull | baseprepad96 | 0.729 | 1.969 | 1.811 | 0.271 | 133868 | 14 | -3.8% [-4.3%, -3.6%] |
| JsonParseSerializable | base | 0.746 | 1.987 | 1.807 | 0.288 | 141465 | 15 | -1.8% [-2.4%, -1.2%] |
| JsonParseSerializable | var | 0.761 | 2.020 | 1.818 | 0.282 | 138605 | 15 | — |
| JsonParseSerializable | prepad8 | 0.758 | 2.013 | 1.832 | 0.289 | 142038 | 16 | -0.7% [-1.2%, -0.1%] |
| JsonParseSerializable | prepad32 | 0.769 | 2.020 | 1.816 | 0.285 | 145205 | 15 | +1.0% [+0.8%, +1.8%] |
| JsonParseSerializable | prepad48 | 0.732 | 2.013 | 1.811 | 0.284 | 151051 | 15 | -4.0% [-4.6%, -3.1%] |
| JsonParseSerializable | prepad96 | 0.763 | 2.007 | 1.806 | 0.286 | 143357 | 15 | +0.1% [-0.6%, +0.9%] |
| JsonParseSerializable | baseprepad8 | 0.748 | 1.997 | 1.816 | 0.291 | 141566 | 15 | -1.8% [-2.5%, -0.8%] |
| JsonParseSerializable | baseprepad32 | 0.749 | 1.994 | 1.811 | 0.290 | 141791 | 15 | -1.8% [-2.5%, -0.9%] |
| JsonParseSerializable | baseprepad48 | 0.716 | 1.991 | 1.808 | 0.292 | 140024 | 15 | -5.8% [-6.2%, -5.6%] |
| JsonParseSerializable | baseprepad96 | 0.744 | 1.989 | 1.805 | 0.290 | 141062 | 15 | -2.2% [-3.0%, -1.6%] |
