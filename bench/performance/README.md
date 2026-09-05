# PR #34 performance measurements

`kemal_ab.py` builds each arm from its own checkout, checks its gcry shard,
then rotates the order each round. Linux only (`/proc`); Python standard
library, Crystal, shards, and wrk are required. Build sequentially and do not
edit a source tree during the build/run. An existing shard lock is shared with
new worktrees; mismatched existing locks are rejected. If no arm has a lock,
the first arm resolves dependencies once and the others use that lock. Use a quiet host.

Example `arms.json` (replace checkout paths):

```json
[
  {"name": "boehm", "root": "/path/to/gcry", "flags": ["--release"]},
  {"name": "null", "copy_of": "boehm"},
  {"name": "base", "root": "/path/to/reviewed-pr34"},
  {"name": "candidate", "root": "/path/to/gcry", "env": {}}
]
```

Default flags are `--release -Dgc_none -Dgcry_headerless`. Set flags explicitly
for header builds; use `GCRY_BITMAP_ALLOC=1` in `env` for bitmap with headers.
`copy_of` uses exactly the reference binary and environment for a null arm.
Inherited `GCRY_*`, `EC_PARALLELISM`, and `CRYSTAL_WORKERS` are removed; put
every arm's tuning variables in its `env` object.

```sh
python3 bench/performance/kemal_ab.py arms.json /tmp/gcry-ab --rounds 20
python3 bench/performance/analyze.py /tmp/gcry-ab/trials.jsonl base
python3 -m unittest discover -s bench/performance -p 'test_*.py'
```

The output directory must not exist. It includes build logs, binaries/hashes,
source manifest, raw wrk/server output, GC snapshots, and every trial including
failures. Publish the manifest, configuration, trials, analysis and findings;
keep binaries outside git. The analyzer refuses errors, incomplete pairs,
duplicate pairs, and incomplete runs detected from the manifest. It requires
`clk_tck`; do not silently assign a tick frequency to historical records.

Rates use completed requests divided by monotonic time around the wrk process,
including its startup/exit overhead, with a separate warmup. Use sufficiently
long trials (15 seconds by default), a null arm, and repeated sessions. Peak
RSS includes startup/warmup; post-GC RSS is recorded separately. GC snapshots
and their allocations are outside the timed load window. CPU/fault deltas
bracket that window. The ratio CI and t-statistic both use per-round ratios;
Student-t critical values are conservatively rounded down in degrees of freedom
when the table has a gap. Request errors invalidate the run, rather than being
discarded. Tiny smoke runs validate the harness, not performance.

## Allocation benchmark

`bench/micro/alloc_ns.cr` preserves the original scratch benchmark's 4096-slot
ring and batched per-thread timing; it adds a ready barrier, size/kind controls,
JSON output, aggregate elapsed time, and collection/pause deltas.

```sh
crystal build --release -Dgc_none -Dgcry_headerless bench/micro/alloc_ns.cr -o bin/alloc_ns
bin/alloc_ns 1 5000000 48
bin/alloc_ns 4 200000 8192 atomic
```

`ns_per_alloc` is the mean per-thread cost; `aggregate_ns_per_alloc` is wall time
divided by all threads' allocations. They are different metrics. Counters after
thread exit are process-cumulative diagnostics, not timed-window hit rates.
Use bounded allocation counts when disabling automatic collection; 8 KiB grows
the heap much faster than the original 48-byte case.

## Graph benchmark

`gc_phases --size=N` means N eight-byte words. Every survival setting gets a
fresh subprocess. With fanout, N churn slots point into a stable N-object target
graph; target objects also carry the requested fanout. This bounds reachable
objects at 2N, and newly allocated objects retain the same edge density instead
of thinning the graph. Output verifies graph objects/bytes/edges after the timed
window. Occupancy includes unswept garbage and is labelled separately.

Use `--trace-only` for repeated collections with no timed mutator allocation,
`--atomic --fanout=0` for pointer-free controls, and `--shuffle` for scatter.
These are new workloads; do not splice their timings into the old graph tables.

`GCRY_ROOT_PHASE_TIMING=1` provides last-full-collection root attribution in
`/gc-stats`. Root fiber time includes its scans and metadata/probes. This is a
first attribution pass, not a change to scan coverage; use a real application
profile before subdividing or optimizing further. The renamed allocation fields
are `cursor_hit_allocations` and `bitmap_locked_allocations`; old getter aliases
remain for compatibility. Locked-path counts remain best-effort across concurrent
size classes, so do not use them as an exact ownership or accounting invariant.


For paired allocation or trace costs with an identical-binary null:

```sh
python3 bench/performance/micro_ab.py bin/alloc_base bin/alloc_candidate /tmp/alloc-ab \
  --rounds 20 --args 4 200000 8192
```

Compile the same benchmark source in both trees and record build commands and
commits alongside the binary hashes. The micro runner records each process's
JSON, configuration and stdout; a failed process invalidates the run. Its ratios
are **cost ratios** (candidate/base, lower is better), unlike HTTP throughput
ratios. Graph trace-only runs use `--metric pause_per_gc_us` and one survival.


## Header-policy factorial experiment

The benchmark-only `BENCH_HEADER_POLICY=base|warm|adaptive|coupled` switch
configures an existing header heap before the workload; it is not a collector
configuration knob and rejects bitmap builds. `warm` retains a live-following
budget under the fixed threshold; `adaptive` changes only the threshold;
`coupled` enables both. Use each arm's `gc_threshold`, `adaptive_threshold`,
and `empty_chunk_warm_retain` snapshot to verify it was applied.

The same control is available in Kemal and `bench/micro/header_churn.cr`, a
single-main-thread 8 KiB ring churn. The latter deliberately avoids creating a
worker alongside main, which would select the multi-mutator release policy.
Compile it with `--release -Dgc_none`. The micro runner accepts
`--base-env BENCH_HEADER_POLICY=base --candidate-env BENCH_HEADER_POLICY=coupled`
(and preserves the base environment in its null arm). No header default is changed by this
experiment. In HTTP configs put this setting in each arm's `env` explicitly.


## Refill availability index

Available chunk addresses are indexed per size class and atomic kind, sorted
once per capacity generation, and checked against the current chunk index before
use. Explicit free, sweep reclamation, and retirement of a non-exhausted cursor
invalidate the generation. Exhausted pools also cache the absence of dormant
chunks, except when a revive was refused during a live flush walk. Cached
addresses neither own nor pin chunks; optional metadata mmap failure falls back
to the previous full search. This preserves lowest-address selection without
changing chunk layout or the in-flight ownership protocol.

Explicit frees currently invalidate the class index rather than incrementally
inserting a single address. This favors ordinary GC churn; measure free-heavy
workloads separately. Metadata is released when the heap is destroyed. Root
coverage and the adaptive policy are unchanged.
