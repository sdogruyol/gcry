# Regression 1's drift in suite order: the Monitor's dead stack (2026-11-04)

Branch `reg1-040`, on `release-0.40.0` (`2b3626b9`). Follows
`bench/log/linux/2026-11-02-scrub-band/` § 4, whose spec-side scrub
(`374dd89e`) covered the dead frames below `drift_cycle` only.

Status (2026-11-03, Reg1b's continuation): two causes found and fixed in
`src/` (the execution-context Monitor's dead stack, § 2–3, and its loop
frame's half-written words, § 6), one spec construction fixed spec-side
(§ 4). **Not closed**: the fixed tree still fails regression 1 on Crystal
1.22.2 headerless, by −1 849 to −2 444 (§ 6.3, § 5), with no root word
changing inside the window in the one instrumented capture.

## 1. Rates before, tip `2b3626b9`

Each binary holds this worktree's `process_spec` files in `crystal spec`'s
glob order (`Dir["process_spec/**/*_spec.cr"]`), cut after regression 1
(54 files). One run per process, each under the shared lock, arms
interleaved. `rates/<arm>.txt` has one line per run (`loop.sh`'s summary).

| config | runs | regression 1 fails | drift (count=10000 cycle) |
|---|---:|---:|---|
| headerless, 1.21.0 (`hl`) | 29 | 0 | |
| `-Dgcry_block_headers`, 1.21.0 (`hdr`) | 28 | 1 | −50 005 |
| headers + `GCRY_BITMAP_ALLOC=0` (`hdrba0`) | 28 | 3 | −50 002, −15 985, −70 174 |
| headerless, 1.22.2 (`hl122`) | 28 | 0 | |

The 1 000-count cycle read −2 / −3 every time. The instrumented copies
(below) on `hdrba0` failed 4 times in 50 runs (−20 173 twice, −15 985,
−50 001). Every failure is negative and large: objects alive at the baseline
reclaimed inside the measured window.

Other failure: `hdr` run 2, regression 21 ("controls kept 8 > 1") with 21's
`GC_stackbottom` example pending, i.e. the main fiber had moved
(`rates/tip-hdr-2-regression21.txt`). Not investigated here; 21's
moved-main-fiber fix (regression 103) is on this tree.

## 2. What is reclaimed, and what held it

`diag/` holds the copies. `d1` (`diag3.cr`'s first form) prints `live_objects`,
collections and finalizer entries after each collection. `d2`/`d3` add a
root recorder in a copy of `src/` (`diag/root-recorder.diff`,
`-Dreg1_diag`): every root candidate that first-marks a block is logged with
its source, the slot it was read from (`Roots.hl_slot`) and the block. After a
failing cycle the copy prints the records whose block is gone, the thread or
fiber stack each slot lies in, `/proc/self/task/*/syscall` (each thread's
SP while blocked), and every fiber stack `allocate_stack`/`free_stack` made.

- **No finalizer is involved.** The finalizer entry count is the same at
  every step (145–148). The drop lands in one collection, and which one
  varies: post0 (`d3`), post1 and post2 (`d1`, both −20 173), post3 (`d2`)
  (`diag/d1-failing-runs.txt`, `d2-failing-run.txt`).
- **The holder is two words on the Monitor's (SYSMON's) stack.**
  `diag/d3-failing-run.txt`: slots `bottom−6064` and `bottom−6056` of
  SYSMON's stack, source `Parked` (its main fiber is read by
  `scan_all_fiber_roots`, more than one mutator thread being alive: the
  staging spec's `Parallel` context), held `0x78093c200000` and
  `0x78093ca00000` through all four pre-baseline collections and were gone at
  the first one after it. The first is a fiber stack's base: allocated at
  collection 100, **freed at collection 102** by `StackPool#collect` on the
  Monitor; the second is that stack's top (base + 8 MiB). gcry had since
  mapped chunks over the range, and both addresses fell inside large blocks
  (chunks `0x78093c1c2000`, `0x78093c97c000`), which kept them and the
  50 001 objects they reached. When reported the same slots held another
  freed stack's base and top: the next `collect_stacks` had written over
  them, inside the window. `d2`'s failure is the same slot (`bottom−6064`,
  a 2 MiB-aligned value inside a large block).
- **The slots are dead stack.** SYSMON's SP while it sleeps was
  `0x780982ffdad8`; the slot at `0x780982ffd850` is **648 bytes below it**.
  gdb on the tip (`gdb_lowwater.py`; its breakpoint offset is `tip_hdr`'s
  `drift_cycle`) has the Monitor's sleep chain end at that SP and its touched
  stack 1 072 bytes below it.

Why: on Linux the Monitor is signal-exempt and publishes no SP, so a stop
reads its stack whole from the low-water mark
(`scan_other_thread_fiber_ec1`, and `scan_all_fiber_roots` with several
mutators), and words its deeper calls left below where it sleeps are roots.
`collect_stacks` runs every 5 s, `free_stack(stack.pointer, stack.size)`
leaves the freed mapping's base and top at that depth, and the 10 ms passes
do not reach it. A freed fiber-stack range that gcry maps chunks over turns
those words into interior pointers. The ROADMAP's open remainder of
`make parallel-dormant` ("the execution-context monitor's frames … hold a
word") may be the same source [INFERENCE; not measured].

## 3. Fix (`src/gcry/monitor_gate.cr`) and regression 105

`MonitorGate.leave`, at the end of each gated call (transfer, increase
parallelism, collect stacks), zeroes 16 KiB of the Monitor's stack below its
SP (less 256 bytes for the `memset` frame), then the band with
`Roots.wipe_below_sp`, before `busy` clears, so a stop never reads it half
done. Linux only: Darwin and Windows suspend the Monitor and scan it from its
SP. The shape is `IdleRelease.scrub_dead_stack`'s, kept separate so the idle
thread's frames (regression 104) do not move. Cost: three 16 KiB clears per
10 ms Monitor pass, on the Monitor's thread.

Research hooks: `MonitorGate.residue_kept` (control arm) and
`MonitorGate.test_plant` / `test_plants` (each gated call writes a masked
block address over 8 KiB below `enter`).

`process_spec/regression/105_monitor_dead_stack_spec.cr`, each arm in its
own process (block made on a scrubbing fiber, held in an atomic static until
planted, then three collections):

| build | fixed | control | unplanted |
|---|---|---|---|
| debug, 1.21.0 | freed | kept | freed |
| `-Dgcry_block_headers` | freed | kept | freed |
| headers + `GCRY_BITMAP_ALLOC=0` | freed | kept | freed |
| `--release` | freed | kept | freed |
| `--release -Dgcry_block_headers` | freed | kept | freed |
| 1.22.2 headerless, 1.22.2 headers | freed | kept | freed |

The first `--release` runs kept the block in every arm: the holder was the
static `Monitor105Hold::block` itself (found by scanning `/proc/self/mem`),
whose clearing store the optimiser dropped; the hold is an `Atomic` now.

## 4. The spec's own frame (`process_spec/regression/1_…`)

`drift_cycle`'s frame (0xd78 bytes plus six pushes in a `hdr` debug build)
is built over earlier examples' residue, and the scrub inside it starts below
it. `probe/probe1.cr` (standalone, not a spec) learns, in a first cycle, which
of the frame's words still hold a sentinel when the pre-baseline collections
run (552) and which of those are written before the first collection after
the baseline (292), then plants a dead finalizable graph's address in those
292 slots before a second cycle from the same call site:

| arm | cycle 2 drift |
|---|---:|
| control (plant) | −4 003 (post0 runs the finalizer, post1 reclaims) |
| fixed (plant, then the caller scrubs before the call) | 0 |
| unplanted | 0 |

No natural failure was traced to this frame; the probe shows the spec relied
on it. The `it` block now calls `drift_scrub` before each `drift_cycle`. The
bounds are unchanged.

## 5. Rates after

Reg1's runs on `59f63197` (§ 3–4 fixes, before § 6): `hdrba0` 0 of 13,
`hdr` 0 of 6, `hl` 0 of 6, `hl122` 0 of 6, `d4` copy 0 of 14.

On the final tree (`release-0.40.0` at `6a76d3dc` + this branch), same
prefix construction, now 57 files (regressions 106 and 107 sort before 1):

| config | runs | regression 1 fails |
|---|---:|---:|
| headers + `GCRY_BITMAP_ALLOC=0` (`rba0a`, `rba0b`) | 20 | 0 |
| headers (`rhdr`) | 10 | 0 |
| 1.22.2 headerless (`rhl122`) | 9 | **1** (`drift=-1849`) |
| 1.22.2 headerless, full suite, 103 files (`rfull122`) | 25 | 0 |

**The ≥100 / ≥50 / ≥50 zero-failure target is not met**: the 1.22.2
headerless prefix failed in its second run (§ 6.3), and the loops were
stopped there, sharing the lock with another agent at ~15 min a round.

## 6. The 1.22.2 headerless failures

### 6.1 Searching

The full-suite copies are `rates/d4full.txt` … `d7full.txt` (Reg1's root
recorder over Reg1's fixed tree `dwt2`, 1.22.2 headerless, 2–3.5 min a run).

| copy | adds | runs | regression 1 fails |
|---|---|---:|---:|
| `d4full` (Reg1) | per-collection counts, root recorder | 8 | 0 |
| `d5full` (`diag2/diag5.cr`) | 40 more 10 000-cycles per process at the same position | 8 (336 windows) | 0 |
| `d6full` | the site report below | 12 | 1 (`drift=-2151`) |
| `d7full` (`diag2/diag6.cr`, `mark-parent-recorder.diff`) | every first mark of the last pre-baseline collection with its parent | 40 | 0 |

No window after the first in a process drifted (`d5full`): the event belongs
to cycle 1, not to anything periodic.

### 6.2 The Monitor's loop frame (fixed)

`d6full`'s site report lists every root word that first-marked a block in
the last pre-baseline collection and holds something else after the check
(`diag2/d6-sites.txt`). In 2 of 12 runs there was exactly one, and in the
other 10 none: SYSMON's stack at `bottom-4952` and `bottom-4920`,
`0x713506dd2e24` → `0x713523d54b04` and `0x71391b03ac69` →
`0x71392a4d7cfa`, the block it named alive both times (drift 0). gdb on
the same binary (`diag2/gdb_site.py`) puts both slots in Crystal's
`Monitor#run_loop` frame, 0xb8 and 0xd8 above its SP, and the disassembly
stores only `%eax` there: the `Int32` nanoseconds of the `Time::Instant`s
`start + @every` and `start`. The other 4 bytes are never written, and
`run_loop` never returns, so they keep what the thread's birth left at that
depth: the high half of an address in the heap's region. The word is a new
address in that 4 GiB every 10 ms pass (low half < 10^9), and keeps whatever
it names until the next pass. That is the parked-seed FINDINGS' "Monitor
word" (low half ≈ 10 ms there: the `remaining` span), which it left open as
Crystal's frame. [INFERENCE] it is also Reg1's `-2444` (same configuration,
a block alive at the baseline let go inside the window); that run was not
instrumented.

Fix (`src/gcry/monitor_gate.cr`): the `run_loop` prologue, after `settle`,
zeroes the stack the birth touched below it (`MonitorGate.scrub_loop_stack`,
the pagemap low-water mark or 64 KiB, the shape of `IdleRelease`'s birth
scrub) and wipes the band frameless; Crystal's loop is reached through a
`@[NoInline]` redefinition so its frame is built after the scrub even in
`--release`. All platforms (the frame is above the SP everywhere), once per
process. Over-retention only.

Regression 107 (`process_spec/regression/107_monitor_loop_frame_spec.cr`,
`GCRY_MONITOR_LOOP_TEST`, read in `GC.init` because the Monitor starts
before any spec; each arm its own process; `diag2/r107-matrix.txt`):

| build | fixed | control | unplanted | halves fixed | halves control |
|---|---|---|---|---|---|
| 1.21 debug | freed | kept (5 words) | freed | 0 | (passed) |
| 1.21 headers | freed | kept (5) | freed | 0 | 11 |
| 1.21 headers, `GCRY_BITMAP_ALLOC=0` | freed | skip (0 words) | freed | 0 | 1 |
| 1.21 `--release` | freed | kept (141) | freed | 0 | skip (0) |
| 1.21 `--release` headers | (passed) | kept (141) | (passed) | 0 | skip (0) |
| 1.22.2 debug | freed | kept (2) | freed | 0 | 9 |
| 1.22.2 headers | freed | skip (0) | freed | 0 | 9 |

Whole planted words survive only in slots the loop never writes, and how
many varies with the build and the pass (0, 2 and 5 in three 1.22.2 debug
runs); the halves arms plant `LOOP_MARKER` and count words that keep its
high half under a low half the loop wrote, which every debug build has.
Each build has at least one control arm that fails before the fix. A first
version made the block with 24 000 bytes in a chunk the Monitor's cursor
held; it read allocated after the collections in every arm, the unplanted
one included, with nothing pointing at it ([INFERENCE] a cursor's claim,
the case regression 106 fixed); the block is now large and the check uses
`find_live_object_with_chunk`.

### 6.3 Not the Monitor: `-2151`, `-1849` (open)

`d6full` run 10 (`diag2/d6-run10-failure.txt`): `count=10000 drift=-2151`,
the drop at post0, finalizer entries 149 throughout. No block a root
first-marked in the cycle was gone, and no root word changed between the
last pre-baseline collection and the check. So the 2 151 objects were
reached through something that is not a recorded root: a live heap object
that dropped them inside the window, or a pending finalizer or callback
closure (`mark_metadata_roots`, not recorded) [INFERENCE]. In that run the
main fiber ran on the `DEFAULT-0` thread and the main thread ran another
fiber. `d7full`, which records each first mark's parent to name that
holder, did not fail in 40 runs.

On the final tree, with § 6.2's fix, the prefix binary on 1.22.2 headerless
failed run 2 with `count=10000 drift=-1849 | count=1000 drift=0`
(`rates/rhl122.txt`): the same size class, so this source is still there.
Its cause and whether it is gcry's or the suite's are open.

## 7. Keep rule

`acd6d3e4` (§ 3): perf A/B on `reg1-040` at `3fd75945` against `v0.39.0`,
nine benches, 15 reps, Boehm, pads `p16 p64 bp16 bp64`: runs 41492282987
(ubuntu-latest, ubuntu-24.04-arm, windows-latest, macos-15-intel) and
41496538104 (macos-latest). `keep.py` (`ab/keep.txt`): every row `ok` or
`placement`, **none unexcused**. The PEAK flags (macOS JsonParse*,
arm64/Windows JsonParse*) are the ones every 0.40 run shows against v0.39.0
(`2026-11-03-reg21-marked-unmarked/ab/keep.txt`), and the fix is Linux only.

§ 6.2's fix: run 41548974920 (`probe/reg1b-keep` at `292fe822`, the same
inputs; `ab/keep-loop-frame.txt`). Every row `ok` or `placement`
except two on ubuntu-latest: JsonParsePure time +4.4% [+3.8, +5.0] and
JsonParseSerializable +2.7% [+2.5, +3.0], wall level. Attribution
[INFERENCE, not re-run]: the fix runs once per process, at the Monitor's
start, so it has no per-collection or per-allocation cost to show; the
same ubuntu-latest JsonParse* rows were unexcused or wide placements in
earlier 0.40 runs on unrelated changes (`2026-11-02-pace-growth/ab/41293138039-keep.txt`
+5.3% / +8.0%, `2026-11-02-scrub-band/ab/keep.txt` +5.9% / +7.4%), and
this run's ubuntu-latest drew a slower machine (JsonParsePure base 0.847 s
against 0.590 s in 41492282987). A re-run would settle it.

## 8. Checks on the final tree

`7bfb0358` on `6a76d3dc` (`rates/checks-final.txt`): `verify.sh` green
(format, lint, `spec/all_specs` 307 / 330 / 307, `process_spec` 442 / 443 /
443, 0 failures), `make windows-typecheck`, `make darwin-typecheck`,
`make alloc-entry-frame` (5 examples, 0 failures); `process_spec` on 1.22.2
headerless 442, headers 443, `GCRY_BITMAP_ALLOC=0` 443, 0 failures.

## Files

- `rates/`: one line per run per arm; `tip-hdr-2-regression21.txt`.
- `diag/`: `diag3.cr` (the instrumented copy of regression 1, run against a
  `src/` copy with `root-recorder.diff` applied, `-Dreg1_diag`), the failing
  runs' output, `gdb_lowwater.py`.
- `probe/probe1.cr`: the frame probe (§ 4).
- `diag2/`: Reg1b's copies (§ 6): `diag5.cr`, `diag6.cr`, the mark-parent
  recorder diff over `diag/root-recorder.diff`'s tree, `gdb_site.py`,
  `dump107.cr`, the site lines, run 10's failure, regression 107's matrix.
- `ab/keep.txt`: `keep.py` on 41492282987 and 41496538104.
