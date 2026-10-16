Cells: speed as % of boehm (whole-process wall, boehm/arm) and peak memory × boehm; medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method (`true` measured the same way): 0.5 MiB.

| bench | boehm | tip | tls2x | getspec | pace100 | pace1000 | thr64 | pfw0 | reuse0 |
|---|---:|---|---|---|---|---|---|---|---|
| Binarytrees | 2.303 s, 36 MiB | 93% [87, 99] / 1.87× [1.87, 1.87] | 71% [67, 82] / 1.87× [1.87, 1.87] | 99% [98, 111] / 1.87× [1.87, 1.87] | 91% [88, 99] / 0.97× [0.97, 0.97] | 92% [88, 100] / 2.72× [2.63, 2.92] | 96% [88, 102] / 2.00× [2.00, 2.00] | 91% [87, 100] / 1.87× [1.87, 1.87] | 92% [90, 100] / 1.87× [1.87, 1.87] |
