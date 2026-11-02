# Regression 1's drift in suite order: the Monitor's dead stack (2026-11-04)

Branch `reg1-040`, on `release-0.40.0` (`2b3626b9`). Follows
`bench/log/linux/2026-11-02-scrub-band/` § 4, whose spec-side scrub
(`374dd89e`) covered the dead frames below `drift_cycle` only.

Status: one cause found and fixed in `src/` (the execution-context Monitor's
dead stack), one spec construction found with a deterministic probe and
fixed spec-side, and **one failure left unexplained**: `count=10000
drift=-2444` on the fixed tree, in a full `process_spec` run on Crystal
1.22.2 headerless (§ 6). The ≥100-run zero-rate check was not reached.

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

## 5. Rates after (`acd6d3e4` + `3fd75945` + `59f63197`)

Same prefix construction (55 files: regression 105 sorts before 1 here).

| config | runs | regression 1 fails |
|---|---:|---:|
| `hdrba0` | 13 | 0 |
| `hdr` | 6 | 0 |
| `hl` | 6 | 0 |
| `hl122` | 6 | 0 |
| `d4` copy, 1.22.2 headerless (fixed tree, root recorder) | 14 | 0 (drift 0 in all) |

Before: 4 of 113 tip runs, 3 of 28 on `hdrba0`. 0 of 13 after on `hdrba0`
is not yet evidence (p ≈ 0.3 at the before rate); the ≥100-run target was
not reached.

## 6. Open: −2 444 on the fixed tree, 1.22.2 headerless

The `process_spec` check on Crystal 1.22.2 (full suite, headerless) failed
regression 1 once on the fixed tree: `count=10000 drift=-2444 | count=1000
drift=0` (`rates/fix-ps122-hl-failure.txt`). The
headers and `GCRY_BITMAP_ALLOC=0` 1.22.2 runs passed. A full-suite build of
the root-recorder copy (`d4full`) was built to catch it and stopped before
its first run. Its magnitude matches neither the Monitor class (16–70
thousand) nor the frame probe; it is close to ScrubBand's 1.22.2 headerless
−1 225/−1 457, which had a finalizer. Untraced.

## 7. Keep rule

Perf A/B on `reg1-040` at `3fd75945` against `v0.39.0`, nine benches, 15
reps, Boehm, pads `p16 p64 bp16 bp64`: run 41492282987 (ubuntu-latest,
ubuntu-24.04-arm, windows-latest, macos-15-intel; its macos-latest job was
cancelled without steps) and 41496538104 (macos-latest, completed). Not yet
evaluated with `keep.py`.

## 8. Checks on `59f63197`'s tree

`verify.sh` all green (format, lint, `spec/all_specs` three ways,
`process_spec` 428/429/429 examples, 0 failures), `make windows-typecheck`,
`make darwin-typecheck`, `make alloc-entry-frame` (5 examples, 0 failures).
`process_spec` on 1.22.2: headers 429 / `GCRY_BITMAP_ALLOC=0` 429 examples,
0 failures; headerless 428 examples, **1 failure** (§ 6).

## Files

- `rates/`: one line per run per arm; `tip-hdr-2-regression21.txt`.
- `diag/`: `diag3.cr` (the instrumented copy of regression 1, run against a
  `src/` copy with `root-recorder.diff` applied, `-Dreg1_diag`), the failing
  runs' output, `gdb_lowwater.py`.
- `probe/probe1.cr`: the frame probe (§ 4).
