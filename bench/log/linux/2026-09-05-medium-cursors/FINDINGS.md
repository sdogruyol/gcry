# Medium-buffer cursor dispatch

Baseline: measurement commit `0b73ebc`; candidate: its allocator plus medium-class dispatch. Both use the same committed allocation benchmark, release/headerless builds, a 4096-slot ring, fresh processes, 20 rotated paired rounds and an identical-binary null. Ratios below are allocation **cost**, lower is better.

| Case | Base ns/alloc | Candidate ns/alloc | Candidate/base, 95% CI | Null/base, 95% CI |
|---|---:|---:|---:|---:|
| 8k | 3715.3 | 3677.3 | 98.98% [98.49, 99.48] | 99.79% [99.31, 100.27] |
| 48 | 32.9 | 33.2 | 100.70% [100.19, 101.20] | 100.52% [100.05, 100.98] |
| 8k-mt | 25139.3 | 24135.1 | 96.03% [94.68, 97.37] | 100.43% [99.14, 101.73] |
| 8k-atomic | 1113.2 | 1096.1 | 98.49% [97.58, 99.39] | 100.59% [99.82, 101.36] |
| 8k-atomic-mt | 8115.8 | 6273.3 | 77.45% [75.33, 79.58] | 99.89% [97.73, 102.05] |

The four-thread 8 KiB atomic case improves by 22.5% (CI 20.4–24.7%). The pointerful case improves by 4.0% at four threads and 1.0% at one: scanning the large live ring dominates its collections. This is not a claim about HTTP throughput. The tiny 48-byte case shifts +0.70%, while its identical-binary null shifts +0.52%; it does not isolate a material dispatch regression.

In the single-thread pointerful case, cursor hits rise from about 54 to 186,600 per process and locked bitmap allocations fall from about 200,070 to 13,524. Collection count remains 50. This verifies that the intended allocation path is exercised.

Validation: medium-fit exhaustively matches the general size classifier for all byte sizes 2,049–32,768. Reused dirty buffers are cleared on actual cursor hits across class boundaries; atomic kind and the 32,769-byte large fallback are checked. Four focused specs pass in header and headerless builds. The new medium-buffer process stress plus existing headerless process suite passes (32 examples). The pre-change cursor-hit regression was observed red.

Build commands:
```sh
crystal build --release -Dgc_none -Dgcry_headerless /tmp/gcry-perf-measurement-base/bench/micro/alloc_ns.cr -o bin/alloc_measurement_base
crystal build --release -Dgc_none -Dgcry_headerless bench/micro/alloc_ns.cr -o bin/alloc_medium
```

Each case manifest records binary hashes, exact arguments and tuning environment. Re-run with `bench/performance/micro_ab.py`; The HTTP comparison is recorded below. No acceptance threshold is inferred from a GC-dominated microbenchmark alone.

## Kemal application result

20 rotated paired rounds, fresh servers, 3 seconds warmup and 15 seconds measured
per arm: measurement baseline `0b73ebc`, identical-binary null, medium cursor
candidate `78f5ac7`, and Boehm. All 80 trials completed without request errors.
`kemal/` contains the full measurement rows, manifest and analyzer output.

Medium/base throughput is **101.3% [96.3, 106.4]**: inconclusive. The null is
101.6% [96.4, 106.8], also inconclusive. Mean request rates are 56,320 for base,
56,706 for medium and 53,463 for Boehm. Medium RSS/base is 0.98 and minor faults
are 2.2 per 1,000 requests versus 2.6 for base. This run establishes no HTTP
throughput improvement; retain the allocation findings as microbenchmark claims.
Full server/wrk transcripts and binaries remain in `/tmp/gcry-medium-kemal-fixed`.
The benchmark runner shares the exact shard lock across isolated worktrees and
records its hash; the initial missing-lock build failed before any trial began.


Host limitation: an existing 24-hour soak process was still running during this
session (about 3% lifetime CPU when inspected). No deliberate build or stress
load ran during the HTTP measurement window, but the host was not fully idle.
The null arm and confidence intervals therefore matter; this session should
not be described as an exclusive-host confirmation.
