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

## Measurement (2026-09-05)
- **`bench/kemal/lib/gcry` is an absolute symlink to this checkout.** Every
  Kemal built from a git worktree compiled *this tree's* gcry, so a
  "master" or "old" arm built that way measured the working tree. Re-point
  the link (`ln -sfn ../../.. lib/gcry`) in the worktree before building, and
  check `readlink -f` in the run log. The PR #33 table's "gcry master" row
  was this branch's default mode because of this.
- A benchmark's `require` with an absolute path has the same problem; give
  worktree builds their own copy with a relative require.
- A run that waits on a server must bound every probe (`curl -m`, `timeout`
  around `wrk`) and kill with `-9`; a crashed server wedged a job for seven
  hours.
- **A runner that passes a comma-joined environment must quote it.**
  `run $2 $3 ${4//,/ }` split the expansion into extra positional arguments
  and every arm after the first variable ran the *default* configuration:
  three "tuning" runs measured nothing but noise, and the spread between
  identical arms (±5% at n=9) is the noise floor to remember. Verify an arm's
  configuration from the server's own stats before trusting its number.
- **A gate calibrated against a default is a gate that fails when the default
  moves.** `live-graph-audit`'s 8 MiB walk floor assumed the 32 MiB major
  threshold; the adaptive threshold halved what the sparse walk had to release
  and the gate called itself inconclusive. A harness that measures one
  mechanism pins every other knob it depends on.
- **Run the CI job's own gate list before opening a PR, not a remembered
  subset.** PR #34 went up after a battery of 30 gates and failed CI on
  `make thread-birth-root`, which was not in the battery: the `test` job runs
  23 targets, extracted with
  `sed -n 54,655p .github/workflows/ci.yml | grep -oE "make [a-z0-9_-]+|crystal spec[^#]*"`.
  Extract the list from the workflow every time; a gate that exists is a
  gate CI runs.
- **Never dereference `pthread_create`'s `arg` as a Crystal object.** Crystal's
  `Thread` passes itself; any raw caller passes anything (the thread-birth
  gate passes an obfuscated integer). Ask the heap whether it is a live block
  of the expected type first.
- **A "this thread never allocates" claim is a test, not a comment.** The
  SYSMON exemption rested on one; `Thread#start` allocates the thread's main
  Fiber on it. The gate that caught it (`scheduler-roots`) hung 1 in 22
  contended runs, so: any thread-exemption from a lock regime gets a spec
  that runs the exempt thread's real work alongside the owner and checks
  for shared blocks (`7_sysmon_alloc_race_spec.cr`), and rare hangs are
  hunted with a contended loop that leaves the hung process alive —
  `/proc/<pid>/mem` plus `ptrace` from Python and `addr2line` gave the
  fiber list and the doubly-pushed node with no gdb on the box.
- **Read the load average before and after every measurement, and kill
  what a timed-out run leaves behind.** A `crystal spec` that hit its
  timeout left its binary spinning on 19 cores for an hour; three Kemal
  runs and a microbenchmark table were taken under load 25 and read as
  regressions. `timeout` on the runner does not kill the child the runner
  spawned; `pkill -f crystal-run-spec` after any timed-out spec, and the
  harness prints `uptime` at both ends.
