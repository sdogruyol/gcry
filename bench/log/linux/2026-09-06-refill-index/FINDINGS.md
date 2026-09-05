# Bitmap refill availability index

Baseline: medium cursor commit `78f5ac7`; candidate: that allocator plus the refill index. Release `-Dgc_none -Dgcry_headerless`, identical `alloc_ns.cr`, fresh processes, 20 rotated paired rounds and an identical-binary null. Cost ratios are candidate/base, lower is better.

| Workload | Base ns/alloc | Candidate ns/alloc | Cost ratio, 95% CI | Null ratio, 95% CI |
|---|---:|---:|---:|---:|
| growth-96mb | 68.8 | 63.1 | 91.75% [90.12, 93.39] | 99.28% [98.06, 100.50] |
| growth-960mb | 722.0 | 92.1 | 12.78% [11.44, 14.12] | 100.32% [96.87, 103.77] |
| 8k-atomic-mt | 7313.9 | 1953.0 | 26.80% [26.00, 27.60] | 99.67% [95.90, 103.44] |
| small-48 | 33.5 | 32.1 | 95.83% [95.19, 96.46] | 99.96% [99.27, 100.64] |

The growth cases allocate 96/960 million payload bytes at four threads with
`GCRY_DISABLE_AUTO=1`; **every trial records zero collections**. The 960 MB cost
falls by 87.2% [85.9, 88.6]. Absolute values differ from the earlier scratch
benchmark; these claims use the paired binaries recorded here.

At four threads, 8 KiB atomic churn improves by 73.2% [72.4, 74.0]. Its average
collection count changes from 108.3 to 105.3, and cumulative pause from 389 to
363 ms; those modest changes cannot explain the allocation-time reduction.
The 48-byte guard improves by 4.2% [3.5, 4.8], with 28 collections in both arms.
Application throughput is a separate experiment, not inferred from these costs.

## Design and limits

Each (size class, atomic kind) owns an mmap-backed array of available mapping
addresses under its existing class lock. Rebuild once per capacity generation,
sort in ascending address order, and resolve each popped address through the
current chunk index before checking its flags and occupancy. No chunk layout,
allocation-hit atomics, or cursor in-flight ownership protocol changes.

Free, sweep reclamation and non-exhausted cursor retirement invalidate the
class generation. Exhausted cursors do not. A failed dormant search is cached
until capacity changes; refusal during a live flush walk is not an empty result.
Adding blacklist bits only removes capacity; candidate masks are rechecked.
Changing blacklist mode invalidates the cache. Metadata allocation failure
falls back to the old full search, rather than raising under the class lock.

Explicit frees invalidate the whole class, so free-heavy workloads do not get
the same amortization. The optional address arrays keep their capacity until
heap destruction, starting at 4 KiB per populated class/kind. This is not a
claim of O(1) behavior for arbitrary free/reallocate patterns.

## Validation and reproduction

Four capacity tests cover growth with the default blacklist enabled, atomic-kind
separation, explicit free, collection/retirement reuse, and blacklist disable.
The first draft failed reuse because payload containment excludes chunk metadata;
exact mapping-key resolution fixed it. Both representation suites, process
regressions, invariant checks, ASan, STW property/index/thread-root checks and
fork/OOM gates pass. See the adjacent performance-validation record for precise
configurations and the header-only page-release harness limitation.

Build `bench/micro/alloc_ns.cr` at `78f5ac7` and this commit using
`crystal build --release -Dgc_none -Dgcry_headerless`, then invoke
`bench/performance/micro_ab.py` with each manifest's arguments and environment.
Manifest, complete per-process JSON and analysis are committed. Full stdout
transcripts remain under `/tmp/gcry-performance-raw/2026-09-06-refill-index`.
An existing long-running soak remained active on the host (about 3% lifetime
CPU at inspection); no deliberate compilation/stress ran during these trials.


## Stopped-world lookup correction

The exact mapping-key lookup initially took the index lock unconditionally.
A collector callback can reach allocation while a stopped mutator holds that
lock. The new focused test reproduced the deadlock at a SIGKILL deadline.
The correction follows `chunk_containing`: use the stable index unlocked while
the world is stopped; take the lock otherwise. Both header and headerless
regressions now pass, along with process and index/release-race checks.

The following 20-round cost comparisons isolate this correction against the
indexed allocator above (neither binary contains the atomic enqueue change):

| Case | After/before correction, 95% CI | Null, 95% CI |
|---|---:|---:|
| stw-fix-8k | 100.13% [98.54, 101.72] | 99.53% [98.25, 100.81] |
| stw-fix-small | 99.91% [99.42, 100.39] | 99.85% [99.44, 100.27] |

The initial application run in `/tmp/gcry-final-kemal` was interrupted for the
fix and is not used for claims. Its replacement builds the corrected source
from scratch. The growth-only mechanism is unchanged: an exhausted growing
pool has no cached addresses to resolve.
