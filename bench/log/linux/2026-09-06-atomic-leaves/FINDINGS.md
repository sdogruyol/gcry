# Skip atomic payloads before mark-queue insertion

Baseline and candidate contain the same refill allocator. The only collector difference is the early `atomic_of(chunk, header)` return after setting the mark and recording first-mark attribution. Both are release `-Dgc_none -Dgcry_headerless` builds of the maintained `gc_phases.cr`.

| Graph | Base mean pause, µs | Candidate mean pause, µs | Candidate/base pause, 95% CI |
|---|---:|---:|---:|
| atomic | 1982.2 | 1305.1 | 65.84% [65.44, 66.25] |
| graph | 27575.0 | 27820.0 | 100.93% [99.44, 102.43] |

20 rotated paired rounds per graph, fresh processes, one second of repeated
collections per process, identical-binary null controls. The atomic graph has
100,000 objects of 64 requested bytes and no edges. The pointerful graph has
200,000 objects and 600,000 verified live edges. Neither timed loop allocates
churn objects (`--trace-only`). The metric is mean stopped-world pause per
collection, not one last-collection mark sample or full application throughput.

Atomic pauses improve by 34.2% [33.8, 34.6]. The pointerful result is inconclusive:
+0.9% [−0.6, +2.4]. The atomic null is 100.01%; the graph null is 99.49%
[98.33, 100.65]. This provides no basis for claiming an HTTP mark-side gain at
Kemal's very small GC duty cycle.

The regression was observed red before the change. It checks that both small
and large atomic roots are marked/live without queueing, that a pointer-shaped
word inside an atomic object does not retain its target, and that a pointerful
parent still queues and retains its child. Both layouts, full unit/process
suites, parallel marking/termination, mark audit, fork, and ASan pass.

Reproduce with `bench/performance/micro_ab.py --metric pause_per_gc_us` and each
manifest's arguments; build the baseline at the parent commit and the candidate
at this commit. Complete JSON samples and binary hashes are committed; raw
stdout is under `/tmp/gcry-performance-raw/2026-09-06-atomic-leaves`.
The existing background soak remained active; no additional stress or compilation
ran during these trials. Worker parking, queue metadata and root coverage are unchanged.
