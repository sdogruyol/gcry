# The RSS budget on the tree with parallel mark by default: no change

The question from `../2026-10-05-rss-budget-vs-boehm/`: should the adaptive
threshold's cap floor rise from 64 MiB to 256 MiB (`GCRY_THRESHOLD_MAX`)? That
cut was taken on CI runners with serial mark. Two things changed since:
parallel mark is on by default (`min(2, CPUs − 1)` workers above 32 MiB
live), and a parallel cycle now feeds `mark_scanned_bytes`, so the cap grows
with the heap again.

Setup: `bench/run_crystal_metric_ab.sh`, process-fresh, the same host (12
CPUs, so 2 mark workers), Crystal 1.21.0. Runs 1–2 are 3 trials of six rows
per arm. Runs 3–6 are 7 trials of the three contested rows, alternating arms
(default, cap256, default, cap256). Cells are speed as % of Boehm / peak RSS
× Boehm. The run files are beside this one.

| bench | default | `GCRY_THRESHOLD_MAX=256 MiB` |
|-------|---------|------------------------------|
| Primes | 60.6–60.8% / 0.90× | 73.9–74.5% / 0.92× |
| JsonParsePure | 61.0–62.7% / 0.80× | 69.6–75.9% / 0.83× |
| JsonParseSerializable | 90.0–91.7% / 0.78–0.82× | 75.2–77.9% / 0.97–0.99× |
| JsonGenerate | 105.0% / 0.70× | 105.6% / 0.71× |
| RegexDna | 96.1% / 0.71× | 98.6% / 0.90× |
| Binarytrees | 84.0% / 0.43× | 81.5% / 0.43× |

## What it says

- **The default tree moved.** Parallel mark and the scanned-bytes count took
  Primes from 38% (CI, 2026-10-05 morning) to 61% of Boehm on this host, and
  JsonParsePure from 47% to 62%. All peak RSS stays at or below Boehm's. Host
  and runner differ, so this is direction, not a paired number.
- **The cap is not a free win here.** It buys 13 points on Primes and 9–14 on
  JsonParsePure. It costs JsonParseSerializable 12–16 points and takes its
  RSS to 0.97×. The extra threshold is fresh memory the short run has to
  fault in, and a 0.3 s program pays that instead of the majors.
- **No default is changed.** A cap that trades one row for another is a
  workload choice. `GCRY_THRESHOLD_MAX` stays the knob for long-lived,
  pointer-heavy heaps.
