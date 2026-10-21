# "process GC thread staging records every thread it creates" failed on the new runner image

PR #55's CI (run 39447839844, commit `adb8a2e9`) failed one process_spec example on both x86_64
jobs, Crystal 1.21.0 and 1.22.0, in every configuration: `staged_overflows` expected 0, got 7 to 32.
The same example was green on 0.37.0's CI, and locally on 12 and on 4 CPUs.

## It followed the runner image, not the code

Probe workflow on `ubuntu-latest` (branch `probe/staging-overflow`, deleted), each job printing the
image and the staging counters at that example:

| run | ref | image (kernel) | staged at the example | result |
|---|---|---|---|---|
| 39463376257 | v0.37.0 | 20261012.334.1 (6.17) | total 4, overflows 0 | pass |
| 39463376257 | v0.37.0 | 20261018.339.1 (7.0) | total 654, overflows 14 | **fail** |
| 39463376257 | `a00f5c47` (scan_stack fix) | 20261012.334.1 (6.17), 2 jobs | — | pass |
| 39463376257 | `c2dd2226` (fork buffer fix) | 20261018.339.1 (7.0) | — | **fail** |
| 39463376257 | `c2dd2226` | 20261012.334.1 (6.17) | — | pass |
| 39463376257 | `adb8a2e9` | 20261018.339.1 (7.0) | — | **fail** |
| 39463376257 | `adb8a2e9` | 20261012.334.1 (6.17) | — | pass |

Every job on the 2026-10-18 image failed, v0.37.0 included; every job on the 2026-10-12 image
passed. (A re-run of 0.37.0's own master job, 39115344591, landed on the old image and passed.)

## Why

`crystal spec process_spec` collects the files with `Dir["#{dir}/**/*_spec.cr"]`
(`compiler/crystal/command/spec.cr`), which does not sort: the order is the filesystem's. On the new
image the regression specs that create threads by the hundred run before `process_gc_spec.cr`, so
654 births precede the example against 4 on the old image. A burst like that fills the 64-slot
staging table, which drains published entries and then evicts the oldest, as designed and counted
(ROADMAP, "A full staging table threw away the newest birth — closed 2026-08-22"). The example
asserted the process-wide `staged_overflows` was 0, so it asserted on whatever ran before it.

## Fix

The example now asserts on the difference over its own four threads. Run 39464170321, six jobs at
`12e967f8`: on the new image the counter read 7 and 13 before the example and the example passed;
on the old image 0, and it passed. 211 examples, 0 failures, in all six.
