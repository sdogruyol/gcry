# Parallel mark as a default: two workers, not four

The open question (ROADMAP "Per-collection mark cost…": "a default would
choose the worker count from the CPUs") measured on the mark as it is after
2026-10-04. Probe `probe-pm-default` on `632f8c5`, crystal-metric
`--release`, 5 reps, arms interleaved in random order per rep, whole-process
wall time and total CPU (`ru_utime + ru_stime`), medians.
`pm2` / `pm4` are `GCRY_PARALLEL_MARK=2` / `4` with the documented server
floor `GCRY_PARALLEL_MARK_MIN_LIVE=33554432`. Cells: speed as % of Boehm,
then CPU seconds.

## GC-heavy rows

| bench | runner (CPUs) | gcry | pm2 | pm4 |
|---|---|---|---|---|
| Primes | ubuntu-latest (4) | 38% · 3.29 s | 47% · 3.96 s | 47% · 5.95 s |
| | ubuntu-24.04-arm (4) | 50% · 2.99 s | 51% · 4.25 s | 63% · 4.76 s |
| | macos-latest (3) | 45% · 3.33 s | 49% · 4.64 s | 55% · 5.07 s |
| JsonParsePure | ubuntu-latest | 48% · 3.71 s | 61% · 3.87 s | 60% · 5.75 s |
| | ubuntu-24.04-arm | 51% · 3.10 s | 61% · 3.60 s | 69% · 4.23 s |
| | macos-latest | 47% · 3.57 s | 63% · 3.78 s | 55% · 4.84 s |
| JsonGenerate | ubuntu-latest | 52% · 5.79 s | 61% · 6.20 s | 53% · 11.43 s |
| | ubuntu-24.04-arm | 60% · 4.70 s | 69% · 5.36 s | 71% · 7.27 s |
| | macos-latest | 61% · 5.79 s | 71% · 6.46 s | 68% · 9.78 s |
| JsonParseSerializable | ubuntu-latest | 69% · 2.66 s | 77% · 2.69 s | 72% · 3.77 s |
| | ubuntu-24.04-arm | 74% · 2.28 s | 81% · 2.37 s | 83% · 2.73 s |
| | macos-latest | 71% · 2.81 s | 86% · 2.63 s | 78% · 3.46 s |

Binarytrees, Knuckeotide and Matmul — live sets under the 32 MiB floor — are
within ±3 points of the default in every arm, as the floor intends. Peak RSS
is unchanged by either worker count.

## What it says

- Two workers gain 8–16 points of Boehm's speed on every GC-heavy row on
  every runner except arm64 Primes (+1), for 2–42% more CPU.
- Four workers are better than two only on arm64. On x86-64 and macOS they
  are level with or worse than two on every row, at up to twice the CPU
  (JsonGenerate on ubuntu-latest: 11.4 s against 6.2 s), which is the
  shared-line cost the 2026-10-04 fixes reduced but did not remove.
- So a default would be `min(2, CPUs − 1)` workers with the 32 MiB floor,
  not "one per CPU". The campaigns' `stw_mt+pm4` and `thread_storm+pm4` lanes
  have run thousands of times since the fixes with no gcry fault; a default of
  two would want its own lanes at two.

No default is changed here.
