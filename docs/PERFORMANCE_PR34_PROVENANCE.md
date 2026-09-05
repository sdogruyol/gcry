# PR #34 performance measurement provenance

The starting local head (`9c04dd6`) and reviewed PR head (`b360bcd`) had the same
tracked tree, `a7d47c139f30b586df20a94b2d438478344f0256`, but different histories.
Measurements used isolated local worktrees. Delivery applies only the new
commits on top of the reviewed PR head, preserving all existing PR history.
There is no force-push, merge into master, or unrelated branch rewrite.

Use this mapping when reproducing a benchmark whose findings or manifest names
a local measurement commit. These pairs have the same tracked trees before
later documentation updates; raw trial data and source/binary hashes are not
rewritten to conceal their original build context.

| Local measurement commit | Commit on PR delivery branch | Change |
|---|---|---|
| `9c04dd6` | `b360bcd` | Reviewed baseline |
| `0b73ebc` | `41d47f4` | Measurement infrastructure |
| `78f5ac7` | `e95940b` | Medium cursor dispatch |
| `4d6a5ac` | `669d50f` | Medium Kemal trials / dependency pinning |
| `eca9fa4` | `95b6abf` | Refill availability index |
| `4cc21b7` | `0dc4172` | Atomic-leaf enqueue skip |
| `b93b4ab` | `a412a14` | Header-policy experiment |
| `95b3010` | `2f7de39` | Stopped-world refill lookup correction |
| `3a5cde1` | `22c133a` | Dependency/latency artifacts |
| `a57a114` | `11c59f5` | Retiring cursor capacity / ordered publication |

Benchmarked source variants are described in each findings file. In particular,
the stopped-world cost check uses the refill-only commit with that lookup fix,
so the atomic enqueue optimization cannot explain its result. The application
runner records a digest over every collector source file, the benchmark server,
the dependency lock, compiler, build flags, environment, binary hashes and
monotonic trial durations. The shared dependency lock is saved with application
results so its hash is reproducible.

Incomplete runs are excluded: `/tmp/gcry-medium-kemal` failed dependency setup
before measurement; `/tmp/gcry-final-kemal` was interrupted for the lock fix.
The latter's replacement is `/tmp/gcry-final-kemal-stw`. The finished headerless
implementation is additionally confirmed in `/tmp/gcry-final-refill-kemal`. Raw stdout/server/wrk
logs remain in the temporary directories named by the findings; committed JSON
contains every successful run's full per-process sample and error census.
