Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 1.2 MiB.

| bench | boehm | tip | tls2x | getspec | pace100 | pace1000 | thr64 | pfw0 | reuse0 |
|---|---:|---|---|---|---|---|---|---|---|
| Binarytrees | 1.135 s, 50 MiB | 96% [94, 97] / 0.75× [0.75, 0.75] | 88% [87, 89] / 0.75× [0.75, 0.75] | 90% [89, 91] / 0.75× [0.75, 0.75] | 91% [90, 92] / 0.42× [0.42, 0.42] | 64% [63, 65] / 1.78× [1.74, 1.86] | 98% [97, 99] / 1.49× [1.49, 1.50] | 94% [93, 96] / 0.75× [0.75, 0.76] | 96% [94, 98] / 0.75× [0.75, 0.75] |
