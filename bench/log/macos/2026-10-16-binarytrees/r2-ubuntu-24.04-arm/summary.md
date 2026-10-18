Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.9 MiB.

| bench | boehm | tip | getspec | shl | getspec_shl | noatomic | a64_lse | thr8 | thr32 | pace100 |
|---|---:|---|---|---|---|---|---|---|---|---|
| Binarytrees | 1.023 s, 50 MiB | 77% [76, 78] / 0.75× [0.75, 0.75] | 80% [78, 81] / 0.75× [0.75, 0.75] | 76% [75, 77] / 0.75× [0.75, 0.75] | 79% [78, 81] / 0.75× [0.75, 0.75] | 92% [91, 93] / 0.75× [0.75, 0.75] | 83% [82, 83] / 0.75× [0.75, 0.75] | 72% [71, 73] / 0.57× [0.57, 0.58] | 79% [78, 80] / 0.85× [0.85, 0.85] | 72% [71, 73] / 0.41× [0.41, 0.42] |
