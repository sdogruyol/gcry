# 0.36.0 integration against 0.35.0 and Boehm

`release-0.36.0` at `a5e52df` (layout removal, knob reduction, in-place large
`realloc`, the counter and `free_bytes` fixes, the Windows crash guard)
against master `b18d5c8` (0.35.0) and Boehm. crystal-metric `--release`,
`../2026-10-14-rss-budget-recheck/ab.py`: 7 reps, every arm once per (rep,
bench) in random order, the whole run under a host-wide lock so no other job
ran beside it. Whole-process wall time (setup included) and `ru_maxrss`,
medians; cells are speed as % of Boehm / peak RSS × Boehm (`table.md`,
`runs.json`). Linux x86_64, 12 vCPUs, Crystal 1.21.0. Checksum mismatches
(`err result=…`) are the same in every arm, Boehm's included.

| bench | Boehm | 0.35.0 | 0.36.0 |
|---|---:|---|---|
| Binarytrees | 0.506 s, 51 MB | 93% / 0.76× | 93% / 0.76× |
| Primes | 0.630 s, 659 MB | 99% / 0.94× | 101% / 0.93× |
| JsonParsePure | 0.814 s, 688 MB | 99% / 0.83× | 98% / 0.80× |
| JsonGenerate | 1.521 s, 1308 MB | 99% / 0.65× | 104% / 0.59× |
| JsonParseSerializable | 0.856 s, 559 MB | 99% / 0.89× | 102% / 0.79× |
| JsonParsePull | 0.847 s, 547 MB | 100% / 0.91× | 102% / 0.82× |
| RegexDna | 2.358 s, 512 MB | 99% / 0.53× | 99% / 0.53× |
| Revcomp | 1.940 s, 970 MB | 96% / 0.58× | 97% / 0.55× |
| Knuckeotide | 0.666 s, 40 MB | 95% / 1.80× | 96% / 1.58× |
| Brainfuck (allocates nothing) | 2.517 s, 14 MB | 98% / 1.00× | 98% / 1.00× |

- No row is slower than 0.35.0 beyond the 1-point spread Brainfuck shows.
  The realloc-chain rows gain 2–5 points of whole-process wall and lose
  10–12% of peak RSS (in-place growth).
- Every row except Knuckeotide is at or under Boehm's peak; Knuckeotide is a
  40 MB process whose peak is the threshold floor and warm budget
  (`../2026-10-14-rss-budget-recheck/`), 23 MB over Boehm.
