# Regression 21's kept controls: the collector's own frames, read as another thread's stack (regression 103)

Branch `ci21-040`, on `release-0.40.0` at `96956b42`. This picks up the
ROADMAP item "Regression 21's 'controls kept 8 > 1'"
(`../2026-11-02-scrub-band/FINDINGS.md`, section 3) and the reproduction
before it (agent CI21: probe `probe/ci21`, 160 runs; local logs in
`/home/naruto/playground/.scratch/CI21/`). The cause is a stop-the-world
root scan, not the write barrier: when the program's main fiber has moved
off the initial thread, the initial thread's pthread mapping is the main
fiber's stack, and it was read whole, the collector's own mark chain below
its SP included.

## 1. Symptom

`process_spec/regression/21_boehm_c_abi_spec.cr:116` ("keeps a block alive
from a `GC_add_roots` range, and only then") fails with "Expected 2" (or
more) controls live, where at most 1 is allowed. It shows in CI's 1.22.2
step (`GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none -Dgcry_block_headers
process_spec`), where the runner's glob order puts 21 at position 94 of 97
(`order_ci.txt`). CI21's probe: 9 failures in 160 runs, every one with the
main fiber moved off the initial thread (21's `GC_stackbottom` example
pending), 9 of the 19 moved runs and 0 of the 141 others.

Locally, the same order with the main fiber moved before the first example
(`mover.cr`: a 60 ms `Fiber.syscall` nanosleep, which the execution
context's monitor hands away) fails every moved run: 15 of 15 across the
diagnostic builds below (`runs/cimove*.txt`, `runs/v3.txt` to
`runs/v9.txt`; `v4`'s second run did not move and passed).

The two controls kept are always the same two blocks: block 0 and block 365
of the 320-byte-class chunk the eight controls share (256-byte atomic
blocks; 336-byte stride with the header). CI21 found them read as marked by
the sweep with no root candidate and no `mark_impl` call landing in their
256 bytes in any of the three collections.

## 2. What marks them

Diagnostic v6 (`diag21.cr`, `diag21-spec.diff`; run through `loop.sh` with
CI's order and the mover) hooks every header-mark write that lands in a
control (`BlockHeader.set_mark` and the allocate-black CAS) and records a raw
unwind, symbolised with `addr2line` (`runs/v6b-1-diag21.txt`):

    set_mark ← hdr_set_mark ← set_block_mark_in ← mark_impl_unlocked
      ← mark_impl ← mark_root_candidate ← scan_pthread_stack
      ← scan_other_thread_stacks (collect_scan.cr:1816, the multi-mutator branch)
      ← run_collection_body ← run_collection ← collect ← GC.collect
      ← gcry_c_gcollect ← regression 21

for controls 0 and 1 in each of the three collections. Control 7, the one
block the example tolerates, is marked through `scan_mutator_stack` (a stale
word on the collector's own stack). The heap at the example's start:
`inc_active=false incremental_marking=false incremental_auto=false
barrier=None`; the barrier rescan hook recorded nothing.

CI21's hooks missed the candidates because they matched `[user, user+256)`.
v9 records the candidate itself: for control 1 it is `0x…08020`, the
chunk's data start, which is block 0's **header** address (user − 16); for
control 0 it is control 0's header address. `find_block_with_chunk` takes a
header address as a pointer into its block (the same acceptance as in
`../2026-11-02-scrub-band/`).

v9 then searches the main thread's stack for the word at the moment the
candidate reaches `mark_root_candidate` (`runs/v9-1-diag21.txt`, first 16
slots): `0x…08020` sits 4 944, 4 904, 4 416, 1 072, 688 and 64 bytes below
the collector's SP at that moment, and 120 to 1 176 bytes above it — the
live frames of the scan chain under `scan_pthread_stack`. The scan was
reading the stack the collector runs on.

(A `previous_def` override of `scan_pthread_stack` in the diagnostic never
ran — `nm` shows the override's callees absent — so v7 and v8 report
nothing; v9 searches from `mark_root_candidate` instead.)

## 3. Why the collector's stack is read as another thread's

Crystal's `ExecutionContext::Scheduler#syscall`: when the monitor has
detached the scheduler during the call, the thread enqueues the fiber back
into its context and checks itself into the thread pool. The initial thread
then resumes `main_thread_loop`, a fiber on a stack of its own
(`ThreadPool#checkin`), and the main fiber resumes on a pool thread. From
then on:

- the initial thread's pthread mapping (`Platform.snapshotted_stack_bounds`)
  is the main stack — the main fiber's stack, running on another thread;
- the initial thread's suspend SP is on `main_thread_loop`'s stack, outside
  that mapping;
- a `GC.collect` from the main fiber runs the whole collection on the main
  stack.

`scan_pthread_stack` with the SP off the mapping fell back to the whole
mapping from its low-water mark (`stw_multi_pthread_lag` 0, the default
since 2026-10-05), so for the initial thread it read the main stack from
its deepest touched page up: every dead frame below the collector's SP, and
the frames being built under the scan itself. The mark chain's locals there
hold `find_block_with_chunk`'s chunk data start and computed block header
for each candidate it resolves, and the scan reads them back as candidates.
The controls' chunk is looked into because a stale word holds control 7
(the tolerated one); its lookup leaves the chunk's data start behind, which
names block 0. The same happens in each collection, so the blocks are kept
for good.

The stop took the multi-mutator branch (the unwind's `collect_scan.cr:1816`;
four threads at the example), which scans every other thread's pthread
mapping. The single-mutator branch scans a thread's current fiber from its
SP and never reaches the mapping here.

### Outside the specs

This is a retention bug in programs, not a test artefact. Any program on
Crystal 1.21+ (the execution-context monitor) whose main fiber has been in a
`Fiber.syscall` long enough for the monitor to hand its scheduler away —
stdlib wraps blocking file-descriptor calls such as `open(2)` and
`getaddrinfo` in it (`crystal/system/unix/file_descriptor.cr`,
`addrinfo.cr`) — has the main stack read whole as the initial thread's at
every collection. After the move the process has the initial thread, the
one running the main fiber and the monitor, which is already the
multi-mutator stop. The collector itself is read when the collection runs on
the main fiber (as here), and the dead frames below the main fiber's
suspend SP when it runs elsewhere. What it costs is over-retention only, never a
premature free: the first block of each chunk the mark looks into, and any
block a dead frame names, with everything reachable from them, kept for as
long as the words stay — and the collector writes them again each cycle.
Finalizers of such blocks do not run and weak references to them are not
cleared.

The fallback has the same shape in v0.36.0 to v0.39.0. v0.39.0 reproduces
regression 103's construction (below): 8 of 8 planted blocks kept in every
arm (`runs/r103-local.txt`).

## 4. The barrier (CI21's suspect)

Not involved. The controls' chunk carries `BARRIER_ARMED` (0x2000), but the
heap's backend is `None` at the example's start: `arm_page_barrier_after_major`
took the barrier down when the earlier spec's sliced cycle ended (the
2026-10-08 fix), and `disarm_mprotect_barrier` unprotected the pages and
freed the cards. The per-chunk bit is left behind; nothing reads it outside
an mprotect dirty-page scan (`scan_mprotect_pages`), and every mprotect arm
rewrites it for each chunk it protects. So the barrier was not left armed,
and the spec process's barrier handling needs no change. The barrier rescan
(`scan_range_for_barrier_pointers`) marks old blocks only in
`collect_a_little`'s termination (a minor's rescan marks nursery blocks
only), never in `collect`, which aborts an open cycle first.

## 5. Fix

`Heap#scan_pthread_stack`, when the thread's own SP is not in its mapping
(or unknown), now asks whether some thread is running on the mapping
(`pthread_scan_low_off_sp`):

- the collector, when its own SP is inside: the scan starts at that SP
  (nothing below the scanning frame is live, and the collector's own scan,
  `scan_mutator_stack`, covers the rest anyway);
- a stopped thread whose current fiber's stack overlaps the mapping and
  whose suspend SP is inside it: the scan starts at that SP less the usual
  red zone and slack (`stack_scan_low`), as for a thread on its own stack.

Otherwise — no thread on the mapping, which is every case but a moved main
fiber, or a thread mid-swap whose current fiber is not yet the stack its SP
is on — the mapping is read as before (the lag window, else whole from the
low-water mark). The scan never shrinks below what the running thread's own
scan treats as live.

Cost: the own-SP test is two compares; the walk is one pass over the thread
list with pointer compares, calling `other_thread_scan_sp` only for a thread
whose current fiber's stack overlaps the mapping. It runs only on the
fallback path. `pthread_scan_running_sp_clamp = false` restores the code
before (regression 103's control arm; no environment knob).

Not taken: skipping the mapping outright when its owner fiber runs elsewhere
(sound only while every running fiber's own scan is known to cover it; the
clamp needs no such argument), and rejecting header addresses as pointers
into their blocks (the scrub-band findings' tradeoff; the frames would still
name blocks by their user addresses).

## 6. Regression 103

`process_spec/regression/103_pthread_stack_running_sp_spec.cr`. In a child
process per arm: the main fiber is moved (at most ten 100 ms
`Fiber.syscall`s; skip marker if it stays, or if the stop takes the
single-mutator scan), eight 256-byte blocks are made on a fiber that scrubs
its frames (addresses kept masked in libc memory), a 512 KiB frame writes
their addresses over its deeper half and zeroes the half under its caller,
and three `GC.collect`s run from the caller. The collector's frames stay in
the zeroed half, so only a scan below the collector's SP reads the plant.

| arm | setting | expected | fix, `823ca9ed` (both layouts) | v0.39.0 |
|---|---|---|---|---|
| fixed | default | freed (≤ 1 kept) | 0 of 8 kept | 8 of 8 kept |
| control | `pthread_scan_running_sp_clamp = false` | kept (≥ 7) | 8 of 8 kept | 8 of 8 kept |
| unplanted | control, no plant | freed | 0 of 8 kept | 0 of 8 kept |

Linux only; the child prints `PSTACK103_SKIP_MARK` elsewhere. On
`ubuntu-latest`, inside the step's whole `process_spec` (round 2 below; the
artifacts of `fixearly` 1 and 5 and `fixlate` 1, 12 runs): 0, 8 and 0 of 8
kept in every run, never skipped.

## 7. Proof

### Locally, CI's order with the move forced

The same 97 files in the runner's order (`order_ci.txt`) with `mover.cr`
first, the header layout, `GCRY_BITMAP_ALLOC=0`, Crystal 1.22.2, one run at
a time under the shared lock (`loop.sh`):

| tree | moved runs | regression 21 failed | other failures |
|---|---|---|---|
| base `96956b42` | 6 of 6 | 6 ("Expected 2 to be LessOrEqual 1") | none |
| fix (`96956b42` + this `src/` change) | 30 of 30 | 0 | none |

`runs/basemove.txt`, `runs/fix30.txt`. The diagnostic builds on
`b1cfbba0` before them failed every moved run (section 1).

### Runners: CI's step on `ubuntu-latest`

Probe `probe/ci21b`, the step looped 4 times per job, Crystal 1.22.2.
Regression 21 runs 98th of 101 files on the fix and 97th of 100 on the base.

Round 2, run 41384381754 (`probe/round2-41384381754.txt`, workflow
`probe/round2-workflow.yml`): the fix at `21462240` and the base, the main
fiber moved in the parent process only — *early* (a `Spec.before_suite`)
or *late* (an example just ahead of 21's):

| arm | runs | moved | failed |
|---|---|---|---|
| fix, early | 40 | 38 | 0 |
| fix, late | 40 | 36 | 0 |
| base, early | 20 | 19 | 0 |
| base, late | 20 | 16 | 0 |

Round 1, run 41378713692 (`probe/round1-41378713692.txt`): the fix at
`823ca9ed` (which differs from `21462240` only in two columns of
whitespace in regression 103), 80 runs with no forced move: 8 moved, 0
failures of 21 or 103, and one failure of regression 100's *remap* control
arm in an unmoved run (below). The round's forced-move arms put the mover
in every child process too and broke regressions 63, 69, 85, 99 and 103's
children on both trees; round 2 replaced them.

So on the fix, 160 runs of the step, 82 of them moved: regression 21 and
103 never failed. The base did not reproduce on the runners with the move
forced (0 of 35 moved, round 2); CI21's 9 of 19 moved failures there were on
`b1cfbba0` with the moves the suite makes itself. What keeps the first
block depends on a stale word reaching the controls' chunk at all (control
7 locally), which the runner's build and heap need not give; regression 103
plants it, and its control arm keeps all eight blocks on every build.

### Regression 100's remap control arm

`rescan100 remap: alive=true pattern intact=false handed out again=false`
in round 1's `fix, 7` run 1, unmoved: the control arm (the code before the
2026-11-02 remap fix) did not lose X. The same line is in CI21's probe on
`c92dcef9` (`b1cfbba0` with its regression 21 diagnostics, job
125028667973), before this change, also in an unmoved run. Not this
change; not chased here.

### Keep rule

Perf A/B, `base` = `v0.39.0`, var = `probe/ci21b` at `d7c6f89f` (the fix's
`src/` on `96956b42`), nine benches, 15 reps, pads `p16 p64 bp16 bp64`,
Boehm. One run per runner: 41378825199 (`ubuntu-latest`), 41378834107
(`ubuntu-24.04-arm`), 41378845352 (`windows-latest`), 41378856093
(`macos-latest`), 41378866065 (`macos-15-intel`). `keep.py` over all five:
`ab/keep.txt`, summaries in `ab/`.

**13 rows are flagged, and same-session pads excuse all 13 ("placement").**
None is unexcused. The largest: macos-15-intel Revcomp +19.1% time (var
2.979, prepad64 2.586 under base's 2.593..2.875), ubuntu-latest JsonGenerate
+4.5% (prepad64 1.389 under base's 1.391), windows-latest JsonParsePull
+4.5% (prepad16 0.685 inside base's 0.667..0.709).

### Checks on the fix tree

- `verify.sh` (after `rm -rf lib/ameba bin/ameba`): spec suites and the three
  `process_spec` configurations green on Crystal 1.21.0 (406/407/407
  examples, 2 pending); format and lint failed on regression 103's constant
  alignment, fixed in `21462240`, after which `crystal tool format --check
  src spec process_spec bench samples` and `make lint` pass.
- `make windows-typecheck`, `make darwin-typecheck`, `make
  alloc-entry-frame` (5 examples, 0 failures): pass.
- `process_spec` on Crystal 1.22.2, all three configurations: 406, 407, 407
  examples, 0 failures, 2 pending.

## Files

- `diag21.cr`, `diag21-spec.diff`: the diagnostic (v9 state) and its
  changes to regression 21, against `b1cfbba0`.
- `mover.cr`, `loop.sh`, `order_ci.txt`: the local reproduction.
- `runs/`: per-run summaries (`ci`, `cimove*`, `v3`–`v9` on `b1cfbba0`;
  `basemove`, `fix30`), v6's and v9's `DIAG21` output, regression 103's
  local results (`r103-local.txt`).
- `probe/`: both rounds' per-run lines and workflows.
- `ab/`: `keep.py` output and the five runs' summaries.
