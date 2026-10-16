Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | boehm | tip | getspec | mac_tsd | shl | getspec_shl | noatomic | a64_lse | thr8 | thr32 | pace100 |
|---|---:|---|---|---|---|---|---|---|---|---|---|
| Binarytrees | 0.814 s, 39 MiB | 81% [76, 83] / 1.79× [1.79, 1.79] | 85% [83, 87] / 1.79× [1.79, 1.79] | 87% [85, 92] / 1.79× [1.79, 1.79] | 84% [81, 86] / 1.79× [1.79, 1.79] | 87% [85, 88] / 1.79× [1.79, 1.79] | 80% [76, 82] / 1.79× [1.79, 1.79] | 79% [79, 81] / 1.79× [1.78, 1.79] | 71% [68, 74] / 0.73× [0.73, 0.74] | 81% [76, 84] / 1.08× [1.08, 1.08] | 78% [77, 80] / 0.95× [0.95, 0.95] |
