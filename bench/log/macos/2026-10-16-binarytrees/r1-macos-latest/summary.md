Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | boehm | tip | tls2x | getspec | pace100 | pace1000 | thr64 | pfw0 | reuse0 |
|---|---:|---|---|---|---|---|---|---|---|
| Binarytrees | 0.829 s, 39 MiB | 80% [79, 83] / 1.79× [1.79, 1.79] | 73% [68, 79] / 1.79× [1.79, 1.79] | 86% [85, 91] / 1.79× [1.79, 1.79] | 80% [77, 83] / 0.95× [0.95, 0.95] | 79% [78, 81] / 3.55× [3.06, 3.77] | 81% [81, 84] / 1.91× [1.91, 1.91] | 80% [79, 87] / 1.79× [1.79, 1.79] | 82% [80, 87] / 1.79× [1.79, 1.79] |
