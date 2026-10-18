Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.3 MiB.

| bench | boehm | tip | getspec | shl | getspec_shl | noatomic | thr8 | thr32 | pace100 |
|---|---:|---|---|---|---|---|---|---|---|
| Binarytrees | 0.746 s, 50 MiB | 88% [87, 90] / 0.75× [0.75, 0.75] | 86% [84, 88] / 0.75× [0.75, 0.76] | 88% [87, 91] / 0.75× [0.75, 0.75] | 88% [84, 90] / 0.75× [0.75, 0.76] | 103% [100, 110] / 0.75× [0.75, 0.75] | 85% [81, 86] / 0.58× [0.58, 0.58] | 91% [90, 93] / 0.85× [0.85, 0.85] | 85% [84, 87] / 0.42× [0.42, 0.42] |
