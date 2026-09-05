# Kemal: header-policy factorial and intermediate headerless comparison

20 rotated paired rounds per arm, 5 seconds measured after a 1-second warmup,
fresh server for every trial, `wrk -t4 -c100 --latency`, `/json`. All **180 trials**
completed with zero connection/read/write/timeout/HTTP errors. This is one Linux
x86_64 session, with the existing background soak still running. The short
measurement windows and wide throughput null interval limit precision.

## Header policies

All four header arms use the same collector/benchmark source and release
`-Dgc_none` flags. `BENCH_HEADER_POLICY` selects base, warm, adaptive or coupled.
A same-binary/environment base copy is the null control. Policy is applied only
by the benchmark helper; no production header default changes.

| Arm | Mean req/s | Throughput/base, 95% CI | Peak RSS, MiB | Faults/1k requests | Post-GC RSS, MiB | Mean per-run request p99, ms |
|---|---:|---:|---:|---:|---:|---:|
| base | 42,613 | 100% | 52.43 | 1,517.6 | 15.52 | 9.74 |
| null | 43,594 | 103.4% [97.4, 109.3] | — | 1,513.6 | — | — |
| warm | 43,253 | 102.4% [96.1, 108.7] | 52.27 | 837.0 | 30.59 | 9.06 |
| adaptive | 42,028 | 99.7% [93.6, 105.7] | 30.90 | 1,389.0 | 15.29 | 7.88 |
| coupled | 42,166 | 100.0% [93.3, 106.6] | 31.34 | 71.4 | 29.26 | 7.27 |
| Boehm | 48,708 | 115.3% [109.2, 121.5] | 24.49 | 3.2 | 24.49 | 6.01 |

Every policy throughput comparison with base is **inconclusive**, not parity.
The coupled policy does have clear memory/latency effects. Paired cost ratios
(`cost-analysis.json`) show:

- Peak RSS −40.2%, CI −41.4 to −39.1%.
- Per-run request p99 −25.4%, CI −27.8 to −23.0%; the p99 null includes no change.
- Post-GC RSS **+88.6%**, CI +85.8 to +91.3%.
- CPU/request +1.9%, CI −4.6 to +8.5%, inconclusive.

The microbenchmark's halved allocation cost does not become a demonstrated
throughput gain here. Smaller thresholds increase collection frequency, while
retention reduces refaults and preserves more resident memory after collection.
The coupled policy deserves a longer independent session and burst/drop/recovery
measurement. Keep header defaults unchanged until those gates resolve the
tradeoff; a more elaborate controller is not justified by this experiment.

The approximate bracketing GC duty is 0.92% for base and 1.98% for coupled.
These deltas include the surrounding stats requests and are not a measurement-
window pause histogram. Request p99 above is kept separate from GC pause p99.

## Headerless rows

This batch also compared the medium-cursor baseline (`78f5ac7`) with the refill
index, atomic enqueue skip and stopped-world lookup correction. It predates the
final retirement/publication correction. Candidate/base throughput is 101.1%
[96.5, 105.7], inconclusive; its null is 97.1% [92.5, 101.8]. Peak RSS ratio is
0.99. The mean bracketing GC duty is about 2.3%, so historical 0.2–0.5% figures
should not be treated as this run's measured duty.

These intermediate rows are retained for a complete record. The final source is
measured separately under `2026-09-06-refill-final/kemal`; use that confirmation
for the delivered headerless implementation.

## Reproduction and artifacts

The manifest records roots, collector/server source digests, flags, environment,
compiler, CPU, binary hashes and dependency lock hash. `shared-shard.lock` is a
byte-for-byte copy verified against every arm. `runner.py` is the actual runner
snapshot for this batch. Replace the temporary checkout paths with worktrees
using [the commit mapping](../../../../docs/PERFORMANCE_PR34_PROVENANCE.md).

`trials.jsonl` is unchanged runner output. `supplement.jsonl` is extracted from
raw wrk/GC snapshots by `bench/performance/extract_kemal.py`. The two analyzer
outputs select the header and headerless references. Cost intervals use the
same paired-ratio method for CPU/request, peak/post-GC RSS and per-run request
p99. Raw server/wrk/GC files and binaries remain in `/tmp/gcry-final-kemal-stw`.
The interrupted `/tmp/gcry-final-kemal` run is excluded.
