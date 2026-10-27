Cells: speed as % of base (whole-process wall, base/arm) and peak memory × base; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.3 MiB.

| bench | base | var | pad16 | pad48 | pad112 | basepad16 | basepad48 | basepad112 |
|---|---:|---|---|---|---|---|---|---|
| JsonParsePull | 1.150 s, 425 MiB | 96% [95, 97] / 1.02× [0.99, 1.06] | 99% [97, 100] / 1.01× [0.98, 1.05] | 99% [98, 102] / 1.03× [0.98, 1.07] | 100% [99, 102] / 1.04× [1.00, 1.06] | 95% [94, 98] / 1.01× [0.96, 1.06] | 99% [96, 101] / 1.00× [0.99, 1.01] | 99% [97, 101] / 0.99× [0.96, 1.01] |
| JsonParseSerializable | 1.186 s, 424 MiB | 97% [96, 99] / 1.06× [1.01, 1.11] | 100% [99, 103] / 1.00× [0.98, 1.02] | 100% [99, 104] / 1.02× [0.99, 1.08] | 100% [98, 102] / 1.03× [1.01, 1.10] | 96% [95, 100] / 0.96× [0.96, 1.03] | 99% [99, 104] / 0.97× [0.96, 1.03] | 99% [97, 101] / 0.97× [0.96, 1.01] |

`var` against `base` (paired, per rep):

| bench | time (timed section) | wall | user | kernel | faults | peak | Σ mark | collections | Σ scanned |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| JsonParsePull | +10.7% [+9.3%, +11.8%] | +3.7% [+2.6%, +5.3%] | +5.8% [+2.0%, +7.4%] | -0.8% [-4.5%, +5.6%] | +2.2% [-0.7%, +4.0%] | +2.2% [-0.7%, +6.1%] | +9.2% [-8.0%, +17.2%] | +8.3% [+0.0%, +8.3%] | +0.8% [-1.5%, +4.2%] |
| JsonParseSerializable | +6.2% [+5.2%, +8.2%] | +2.9% [+1.3%, +4.7%] | +2.4% [+0.7%, +5.1%] | +0.8% [-3.2%, +9.2%] | +4.0% [+0.8%, +7.2%] | +6.1% [+0.6%, +11.1%] | -4.9% [-8.3%, +17.1%] | +0.0% [+0.0%, +0.0%] | +2.5% [-2.0%, +4.3%] |

Per arm, medians over reps (last column: timed section against `var`, paired per rep):

| bench | arm | time | wall | user | kernel | faults | collections | time vs var |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| JsonParsePull | base | 0.368 | 1.150 | 0.996 | 0.207 | 135068 | 12 | -9.6% [-10.6%, -8.5%] |
| JsonParsePull | var | 0.407 | 1.207 | 1.066 | 0.207 | 137035 | 13 | — |
| JsonParsePull | pad16 | 0.371 | 1.172 | 1.029 | 0.206 | 134873 | 13 | -9.6% [-10.3%, -8.2%] |
| JsonParsePull | pad48 | 0.373 | 1.152 | 1.004 | 0.218 | 134341 | 13 | -9.4% [-10.5%, -6.6%] |
| JsonParsePull | pad112 | 0.367 | 1.151 | 1.001 | 0.214 | 138122 | 13 | -9.6% [-11.7%, -8.4%] |
| JsonParsePull | basepad16 | 0.422 | 1.204 | 1.066 | 0.205 | 133031 | 13 | +2.0% [+0.6%, +5.1%] |
| JsonParsePull | basepad48 | 0.383 | 1.179 | 1.038 | 0.205 | 133402 | 13 | -5.9% [-9.7%, -3.9%] |
| JsonParsePull | basepad112 | 0.381 | 1.160 | 1.021 | 0.205 | 132542 | 13 | -7.6% [-9.0%, -3.8%] |
| JsonParseSerializable | base | 0.402 | 1.186 | 1.032 | 0.212 | 140610 | 14 | -5.8% [-7.6%, -4.9%] |
| JsonParseSerializable | var | 0.430 | 1.231 | 1.064 | 0.229 | 149812 | 14 | — |
| JsonParseSerializable | pad16 | 0.393 | 1.178 | 1.035 | 0.212 | 139475 | 15 | -8.5% [-10.3%, -5.7%] |
| JsonParseSerializable | pad48 | 0.398 | 1.163 | 1.022 | 0.216 | 142347 | 14 | -6.7% [-9.2%, -3.4%] |
| JsonParseSerializable | pad112 | 0.398 | 1.186 | 1.028 | 0.222 | 143523 | 14 | -8.3% [-9.9%, -4.9%] |
| JsonParseSerializable | basepad16 | 0.445 | 1.215 | 1.065 | 0.210 | 138457 | 14 | +4.8% [+2.5%, +6.5%] |
| JsonParseSerializable | basepad48 | 0.396 | 1.178 | 1.034 | 0.212 | 138552 | 14 | -7.6% [-9.0%, -6.0%] |
| JsonParseSerializable | basepad112 | 0.403 | 1.193 | 1.060 | 0.213 | 138304 | 14 | -5.5% [-8.0%, -4.5%] |
