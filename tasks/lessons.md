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

## Review fixes
- **"Dead code" has branches.** `clamped_scan_size` looked replaceable by the
  chunk-derived payload, and it was for small blocks; for large blocks it was
  `min(header.size, extent)`, and dropping it made large scans walk the whole
  mapping. Before deleting a helper, diff its result against the replacement
  for every representation it serves (small/large, header/headerless,
  freelist/bitmap), not just the one the review named.
- **Guarded specs are debt.** A `{% unless %}` around a failing example is a
  claim that the property does not exist in that build. Check whether the
  property survives the representation (block reuse did; TLAB refills did
  not) and assert it there before reaching for the guard.
- **A reproduction can pass for the wrong reason.** The stale-tail example
  passed with the fix reverted; the size example did not. Keep the example
  whose failure you actually observed as the pin, and say which one that was.
- **`pgrep -f`/`pkill -f` match the shell running them whenever the pattern
  text — or the *path* it would match — appears anywhere in that command
  line.** The `[f]inal2` trick protects only the pattern string itself; a
  `$S/final2.sh` elsewhere in the same command still matches. Three shells
  were killed this way in one session. Use `ps -eo pid,args | grep "[f]..."`
  in one command to get PIDs, and kill by number in another.
- **Reproduction probes store pointers word-aligned.** A conservative scan
  reads 8-byte words; a pointer at a non-multiple-of-8 offset is invisible
  to it, and the probe then "passes" for the wrong reason.

## Concurrency
- **A read-modify-write on a word the collector also writes is a race even
  with the world stopped**, because "stopped" is a signal that can land
  between the read and the write. Any mutator-side write to a header word the
  collector marks (allocate-black, flags) must be a CAS that re-reads its
  inputs after a failed swap. Found via allocation tags + a "mark generation
  one behind" signature; a static-root control that changed nothing is what
  turned the hunt from the scan to the write.
- **Controls that change nothing are the most valuable instrument.** The
  static-root control (no change) ruled out the scan; the CAS-only run (no
  change) ruled out the header race as the whole story; the scan-range
  record (slot inside) ruled out the range. Each "no change" removed a
  candidate faster than any theory did. Write the control before the fix.
- **A conservative root scan with `base_only` rejects what an allocator
  holds mid-allocation** (`header`, `chunk`): any allocation path must keep
  the user pointer visible, or publish it, from the moment the block reads
  USED until the caller holds it.
