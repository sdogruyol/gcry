# Lessons

Rules written after corrections, so the same mistake is not made twice.

## Branch discipline
- **Implement review fixes on the newest branch that contains the work.** When
  `simdgc-headerless` was forked from `simdgc`, the older branch became
  redundant; a fix landed on it would have to be re-applied. Ask "which branch
  is the one that will ship?" before touching a worktree.

## Instruments that lie
- **An `occ` census is not a liveness census.** Occupancy after a mutator loop
  includes every allocation since the last sweep. Pin the threshold, collect,
  and count *then* — and under lazy sweep, only after the chunk has been swept.
  Retracted twice before this rule was written.
- **The mark bitmap is void after a collection.** Sweep consumes it
  (`occ = mark; mark = 0`), so comparing "marked sets" between builds after a
  collection compares zeros.
- **`Gcry.pause_stats` p50/p99 are process-cumulative.** Cross-arm or
  cross-survival comparisons must use a delta'd instrument
  (`pause_total_ns` before/after), never the percentiles.
- **Kemal cannot judge a mark-side phase.** Its GC duty cycle is 0.2–0.5%; use
  `bench/micro/gc_phases.cr` (`--shuffle --fanout=K`) where a mark change is
  legible, and keep Kemal as the regression guard.

## Shell
- `pkill -f <pattern>` matches the shell that is running it when the pattern is
  in the same command line (exit 144, twice). Use `pgrep`'s pid list from a
  separate step, or split the pattern.
- Anything longer than the harness's 10-minute limit runs under
  `setsid nohup … &` with its own log, or it is killed mid-soak.

## Crystal / gcry
- Constant initializers that compute (`N * 8`, `.to_u64`) fail before `Fiber`
  is up (`GC.init` rule). Chunk constants are literals with the derivation in a
  comment.
- Concurrent `--release` builds of binaries with large static arrays exhaust
  memory and surface as spurious `mmap` failures in *other* processes. Build
  sequentially.
- A probe's root array via `Pointer(T).malloc` is GC-managed and roots
  everything it holds; use `LibC.malloc` for probe bookkeeping.
