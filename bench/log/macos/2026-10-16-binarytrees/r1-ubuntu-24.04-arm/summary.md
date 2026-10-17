Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.9 MiB.

| bench | boehm | tip | tls2x | getspec | pace100 | pace1000 | thr64 | pfw0 | reuse0 |
|---|---:|---|---|---|---|---|---|---|---|
| Binarytrees | 1.109 s, 50 MiB | 82% [81, 84] / 0.75× [0.75, 0.75] | 77% [77, 79] / 0.75× [0.75, 0.75] | 86% [85, 88] / 0.75× [0.75, 0.75] | 79% [78, 80] / 0.41× [0.41, 0.42] | 80% [78, 82] / 1.54× [1.37, 1.76] | 85% [84, 87] / 1.50× [1.50, 1.50] | 83% [82, 85] / 0.75× [0.75, 0.75] | 83% [81, 84] / 0.75× [0.75, 0.75] |
