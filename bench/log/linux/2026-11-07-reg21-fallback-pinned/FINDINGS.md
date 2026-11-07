# Regression 21's "controls kept 8 > 1" a third time: the fallback cursor set's chunks were never swept after the world (regression 109)

Branch `reg21d-040`, on `release-0.40.0` at `b339f533`. SpecHarden's
suite-order runs (`../2026-11-06-spec-harden/`) saw regression 21 fail once
in 174 on Crystal 1.22.2 headerless — "Expected 8 to be LessOrEqual 1",
the main fiber moved off the initial thread (21's `GC_stackbottom` example
pending), output `/home/naruto/playground/.scratch/SpecHarden/reg1/out-new-hl122-59.txt`
— on a tree with both earlier fixes: regression 103 (`21462240`, the
pthread-scan clamp; `../2026-11-03-reg21-marked-unmarked/`) and regression
106 (`2721f940`, a claimed block is not live to `GC_base`;
`../2026-11-04-reg21-claimed-controls/`).

**A third mechanism, neither fix incomplete.** The eight controls were never
swept. The thread running the main fiber allocated through the *fallback*
cursor set, which the stop pinned at every collection, and the after-world
sweep skips a pinned chunk.

## 1. The defect

Each thread allocates through a cursor set of its own, one of a table of
`Heap::MAX_CURSOR_SETS` (64). A thread that first allocates while the table
is full — every set live, or exiting and not yet freed by a stop — gets the
shared fallback set (`cursor_set_under_lock`) and caches it in its
thread-local for the rest of its life. The fallback never takes the hit
path; its users allocate under the class lock.

`bitmap_settle_cursor_sets` treated every set that never takes the hit path
(the fallback, the monitor's, the out-of-memory reserve's) like a set
frozen mid-allocation: chunks `PINNED`, claims marked, at every stop. The
after-world sweep leaves a pinned chunk alone (`sweep_small_bitmap`:
"its owner was frozen inside the unlocked hit path and will hand out blocks
here … without the class lock"), so a chunk the fallback held was never
swept while it held it: every block that died there stayed in `occ`,
allocated in every sense — `GC_base`, `GC_size`, `Heap#live?` — its
finalizer never run, its weak links never cleared, until the cursor ran off
the end of the chunk. The pin protects nothing for such a set: its owners
never hand out blocks without the class lock, and the after-world sweep
takes that lock.

Exposure: the bitmap allocator (the default in both layouts); never under
`GCRY_BITMAP_ALLOC=0`, which has no cursor sets. Any program with more than
64 threads allocating at once, or a thread born in such a window, keeps a
thread on the fallback for good; one chunk per (class, kind) the fallback
holds — 43 pinned chunks at regression 21 in the reproduction below — is
unswept for as long as it holds it. The monitor's own set had the same pin
(three chunks in every run here), and so had the out-of-memory reserve's.
The pin on `no_hit_path` is from `5cb2226c` (2026-09-05): v0.23.0 and every
release since, v0.39.0 included.

## 2. How regression 21 meets it

`process_gc_spec`'s "keeps every thread bounded when the list outgrows the
table" starts `STACK_BOUNDS_INITIAL_SLOTS + 16` = 80 threads. In every
diagnostic run here (§ 3) the table filled at collection 30 and 21 or 22
threads were handed the fallback. When the execution context's monitor moves the
main fiber in that window — it hands a scheduler it finds inside a
`Fiber.syscall` to a pool thread (`../2026-11-03-reg21-marked-unmarked/`
§ 3) — the pool thread that takes it is born with the table full and
allocates through the fallback from then on. Regression 21's `fresh_block`
fibers ran on that thread too (the controls' chunk is in the reading
thread's slot, below), so the controls come from the fallback's chunk of
their class, are freed by nothing, and all eight read live and intact.

A move before the storm (CI21b's mover, first example) gives the pool
thread a set of its own, and 21 passes (0 of 14 moved runs here, below).
After the storm the exited threads' sets stay taken until a stop frees
them, and a move in that window lands on the fallback: the mover placed
right after `process_gc_spec` does, every run. That is why it needs both the
move and its timing, and was 1 in 174 [INFERENCE: what made the natural
move fall in the window is not identified; the address-space examples after
the storm open files, which `Fiber.syscall` wraps].

## 3. How it was found

Reproduction as CI21b's and Reg21c's: the spec files of the failing run's
order (SpecHarden's 57-file prefix, 21 the 17th), one run at a time under
the shared lock (`loop.sh`), Crystal 1.22.2 headerless.

The mover first (`move_main.cr`, `../2026-11-03-reg21-marked-unmarked/mover.cr`)
did not fail: 0 of 14 moved runs, 4 of them under the diagnostic below
(`runs/mv122.txt`, `runs/dg122.txt`).

The diagnostic (`diag/d21h.cr`, `diag/d21h-spec.diff`) is Reg21c's
(`../2026-11-04-reg21-claimed-controls/diag/d21.cr`: root candidates and
mark writes landing in a control, claims covering one, with raw unwinds)
made layout-aware (block `[user − header, user + 256)`, stride from
`@block_bytes`), plus: each control's occupancy, exact allocation, claim,
mark, `GC_base` answer, its chunk's `PINNED`/dormant flags and which cursor
set holds the chunk, after each of the three collections and at the count;
the sweep's pinned-chunk counter; every set and slot at the report; and
every hand-out of the fallback set (thread, collection, set count).

Its first unforced run passed and showed the table full (`count=64`) with
the fallback holding a chunk, the monitor's set three, all four pinned at
every stop (`sweep_cursor_pinned` +4 per collection). Two drivers then put
21's thread on the fallback:

- `diag/fill.cr` + mover (`fmove_main.cr`): 70 threads parked after one
  allocation each, then the move. Forced, and it breaks one
  `process_gc_spec` example that counts threads.
- `diag/latemover.cr` (`ldiag_base_main.cr`, `lmove_*_main.cr`): the mover
  placed right after `process_gc_spec`, nothing else added — the natural
  mechanism, made certain.

Both failed with the natural signature on the first run, every control
(`runs/ldg122-1-d21.txt`, the late mover on the base):

    D21 ctl 0..6 c1=0x34167 c2=0x34167 after_collect=0x34167 at_report=0x34167
    D21 ctl 7    c1=0x34167 c2=0x34177 after_collect=0x34177 at_report=0x34177
    D21 sets: count=64 fallback=0x5ac539c12e90 … own=0x5ac539c12e90 ctl_chunk=0x78f5750a0000
    D21 pinned chunks=43
    D21 fallback 0..20 … collections=30 set_count=64

`0x34167`: occupied, allocated exactly, `GC_base` answers it, the chunk a
cursor's and `PINNED`, held by the reading thread's own set (slot 0x34 = 52,
class 12 atomic) — which is the fallback; not marked, not in the claim.
After the first collection already. No root candidate and no mark write
reached controls 0–6 in any collection, and no claim covered any control
(`claims_on_controls=0`); control 7 is marked through root words (stack in
the first collection, static data in the second), the stale word the
example tolerates. So: not marked, not claimed, not swept.

## 4. Fix

`bitmap_settle_cursor_sets` pins a set that never takes the hit path only
when it is mid-allocation (`in_flight` set, as for any set). Otherwise its
claims are still marked and it is still neither retired nor credited (its
owner may be running: the monitor is not stopped), but its chunks stay
unpinned and the after-world sweep sweeps them under the class lock, the
lock every allocation from such a set holds. The claim survives that sweep
because it is marked, and the sweep takes it back out of the live count
(`chunk_claimed_count`), as for a claim made while a sweep could run. If
the collecting thread is itself on the fallback (as the moved main fiber
here), the sweep may retire an empty chunk's fallback slot under the class
lock (`bitmap_retire_cursor_on`), which no fallback user can be inside.
`cursor_sets_pinned` counts the sets the stop pinned, which is now what its
note says: mutators frozen mid-allocation.

`Heap#no_hit_sets_swept = false` restores the pin (regression 109's control
arm; no environment knob).

Cost: one `cursor_set_mid_allocation?` pass over a no-hit set's slots per
stop (three sets here); the after-world sweep does the work it skipped.

Not taken: giving a fallback thread a set of its own when one frees up (a
hit-path matter for programs past the table, not this defect — it would
still leave threads past 64 on the fallback); making the spec deterministic
(the eight are dead, and the collector kept them).

## 5. Regression 109

`process_spec/regression/109_no_hit_set_chunks_swept_spec.cr`. In a child
process per arm: 64 threads parked after one allocation each, so the table
is full; one more thread makes eight 256-byte atomic blocks through the
fallback (addresses masked in libc memory), scrubs its frames and exits;
three `GC.collect`s from the main thread; then `Heap#live?` / `GC_base` per
block. Skip marker when the blocks are not on a chunk the fallback holds
(always under `GCRY_BITMAP_ALLOC=0`), when no collection swept after the
world (an in-stop sweep ignores the pin, so the fixed arm would pass
vacuously; added after review), or, in the control arm, when no
after-world sweep met a pinned chunk.

| build | fixed | control (`no_hit_sets_swept = false`) |
|---|---|---|
| headerless, 1.22.2 | 1 of 8 kept, freed | 8 of 8 kept, 12 pinned chunks skipped |
| headers, 1.22.2 | 1 of 8 kept, freed | 8 of 8 kept, 12 pinned chunks skipped |
| headers + `GCRY_BITMAP_ALLOC=0` | skipped (no sets) | skipped (no sets) |

In the two fixed-arm runs printed block by block, the one kept was block
0, the chunk's first block, whose address is the chunk's data start;
[INFERENCE] a stale word naming the data start, the class
`../2026-11-02-scrub-band/` describes — the example tolerates one, as
regression 21 does.

## 6. Proof

Suite order (SpecHarden's 57-file prefix), Crystal 1.22.2 headerless, one
run at a time under the shared lock; base `b339f533`, fix `a0df2b7b`.
"Moved": 21's `GC_stackbottom` example pending.

| driver | tree | runs | moved | regression 21 failed | other failures |
|---|---|---:|---:|---:|---|
| late mover (`lmove_*_main.cr`) | base | 10 | 10 | **10** (all "Expected 8") | none |
| late mover + diagnostic | base | 3 | 3 | **3** ("Expected 8") | none |
| fill + mover (`fmove_main.cr`) | base | 5 | 5 | **5** ("Expected 8") | the fill's thread count, every run |
| late mover | fix | 100 | 97 | 0 | none |
| late mover + diagnostic | fix | 3 | 3 | 0 | none |
| fill + mover | fix | 10 | 10 | 0 | the fill's thread count, every run |
| mover first | fix | 30 | 30 | 0 | none |
| mover first (± diagnostic) | base | 14 | 14 | 0 | none |

So 137 moved suite-order runs of the fix (127 without the fill), 0
failures of 21 and none of anything else; the late mover alone, the
natural mechanism made certain, fails the base 13 of 13. "The fill's
thread count" is `process_gc_spec`'s "reads stack bounds for every thread
the snapshot visits", which the 70 parked threads break on both trees.

Under the diagnostic on the fix (`runs/ldgfix-1-d21.txt`), the reading
thread is again on the fallback (`own` = `fallback`) and the controls'
chunk is again in its slot, but every control reads `0x34104` — free,
unmarked, not pinned — after the first collection; no chunk is pinned at
the report, and `sweep_cursor_pinned` stays at 3 for the whole run
against 2 764 on the base.

`runs/`: one line per run (`loop.sh`): `lmvbase`, `ldg122`, `fmvbase`,
`mv122`, `dg122` the base; `lmvfix`, `ldgfix`, `fmvfix`, `mvfix` the fix.

## 7. Keep rule and checks

Perf A/B, `base` = `v0.39.0`, var = `reg21d-040` at `a0df2b7b` (the fix
and regression 109 on `b339f533`), nine benches, 15 reps, pads `p16 p64
bp16 bp64`, Boehm. One run per runner: 42310622557 (`ubuntu-latest`),
42310633046 (`ubuntu-24.04-arm`), 42310642710 (`windows-latest`),
42310652347 (`macos-latest`), 42310661763 (`macos-15-intel`). `keep.py`
over all five (`ab/keep.txt`, summaries in `ab/`): **11 rows flagged, 10
excused as placement, 1 unexcused**: macos-latest JsonParseSerializable,
timed section +3.8% [+0.4, +6.1], wall −0.8% [−3.3, +1.1] (var-code
0.539–0.550 against base-code 0.531–0.535). The largest excused:
windows-latest Revcomp +10.0% time (prepad64 1.050 inside base's
1.048..1.156), macos-15-intel Revcomp +7.3% (prepad64 2.165 inside
2.065..2.203), macos-latest JsonGenerate +5.6% (prepad16 0.915 under
base's 0.941..0.966).

The unexcused row again on `macos-latest`, 21 reps, with JsonParsePull and
JsonGenerate:

- against `v0.39.0` (42317549241, `ab/keep-macos-vs-v0.39.0.txt`): no row
  flagged; JsonParseSerializable var 0.573 against base 0.560, var-code
  and base-code ranges overlapping (0.565–0.573, 0.560–0.566).
- against the tip, `b339f533` (42317539324, `ab/keep-macos-vs-tip.txt`):
  JsonParseSerializable +5.7% [+3.7, +7.4] timed, excused as placement
  (prepad64 0.540 inside base-code 0.521..0.540), with the collector's work
  the same in both: collections +0.0%, Σ mark +0.3%, Σ scanned −1.4%, peak
  +0.4%, user +1.7% [−1.8, +3.8], wall +2.2% [−2.9, +6.4]. JsonParsePull
  +2.4% placement, JsonGenerate −3.3%.

So the row is placement on that runner: it does not reproduce against
0.39.0 with 21 reps, and against the tip nothing the change does differs
[INFERENCE: a single-threaded benchmark has no thread on the fallback; the
change unpins the monitor's three chunks and adds one pass over three sets'
slots per stop].

On the branch's tree:

- `verify.sh` (after `rm -rf lib/ameba bin/ameba`), Crystal 1.21.0: format,
  lint (260 inspected, 0 failures), `spec/all_specs` three ways (307, 330,
  307 examples, 0 failures), `process_spec` three ways (447, 448, 448
  examples, 0 failures; 2, 2 and 3 pending — [INFERENCE] the third is
  21's `GC_stackbottom` example, which pends when the main fiber has moved).
- `process_spec` on Crystal 1.22.2, all three configurations: 447, 448,
  448 examples, 0 failures, 2 pending.
- `make windows-typecheck`, `make darwin-typecheck`: pass.
- `make alloc-entry-frame`: 5 examples, 0 failures.

## 8. After review: a guard for the unpinned chunks

The fix lets sweeps take chunks a running thread allocates from, which no
test exercised: regression 109's fixed arm only checks that dead blocks go.
A sweep or retire of such a chunk under its user (a block handed out and
swept, a claim reclaimed) would show only as a use-after-free. Two guards,
each failing on a mutant (below); the code before was safe here too (it
never swept those chunks), so they guard later changes rather than tell
the trees apart:

- `bench/claim_stress.cr --workers=72` (stamped blocks, cross-thread frees,
  a collection every 0.2–2.2 ms), past the 64-set table, so the threads
  beyond it allocate through the fallback. A run with more workers than the
  table fails unless a worker was seen on the fallback
  (`Heap#on_fallback_cursor_set?`, a public read added for it), and a lazy
  run unless some collection swept after the world. `make claim-stress`
  runs both arms with 72 workers after the 4-worker ones; the overnight
  script loops them (`claim-stress-fallback-lazy`, `-in-stop`, 100 runs
  each, in `stress.yml`'s `mt` shard).
- Regression 109's *stamped* arm: with the table full, one thread on the
  fallback allocates stamped blocks of five classes, atomic and not,
  dropping some, through 20 collections; every kept block must keep its
  stamp and read live. 42 000–44 000 blocks, 20 of 20 collections swept
  after the world, 0 broken (headerless and headers; skipped under
  `GCRY_BITMAP_ALLOC=0`; `runs/r109-layouts2.txt`).

Also: regression 109 now skips unless a collection swept after the world,
and `oom_reserve.cr`'s note on the reserve set no longer says its chunks
are pinned at every stop.

`claim_stress --seconds=5 --workers=72`, seeds 1–50 per arm, Crystal 1.21.0
release build, one run per lock hold (`cs_campaign.sh`;
`runs/claim-stress-72.txt`); the base tree's build is the same source with
`diag/fb_helper.cr` supplying the public read:

| tree | arm | runs | pass | fallback passes (min–max) | after-world sweeps (min–max) |
|---|---|---:|---:|---|---|
| fix | lazy | 50 | 50 | 61–120 | 5–11 |
| fix | in stop | 50 | 50 | 50–107 | 0 (in stop) |
| base `b339f533` | lazy | 50 | 50 | 61–116 | 5–11 |
| base | in stop | 50 | 50 | 44–106 | 0 (in stop) |

The mutant (`diag/mutation.txt`): the fix with a no-hit set's claim left
unmarked when the set is not pinned, so the sweep reclaims blocks the
fallback still holds in its mask. `claim_stress --workers=72` fails all 6
runs (lazy: 2 with 40 broken stamps, 1 SIGSEGV; in stop: 3 SIGSEGV;
`runs/cs_mut.txt`); regression 109's stamped arm fails, 5 781 stamps broken,
each block reading `live?=false` (`runs/mut109.txt`).

On the tree after these changes: `verify.sh` (format, lint 260 inspected,
`spec/all_specs` 307/330/307, `process_spec` 449/450/450 examples, 0
failures, 2 pending), `process_spec` on 1.22.2 (449/450/450, 0 failures),
`make windows-typecheck`, `make darwin-typecheck`, `make alloc-entry-frame`
and `make claim-stress` pass; the late-mover suite order, 10 more runs (9
moved), 0 failures of 21 (`runs/lmvfix2.txt`).

## 9. `--fallback` replaces `--workers=72` (2026-11-07)

The 72-worker arm failed "72 workers and none seen allocating through the
fallback set" in PR CI run 42340290626 (`a40ec329`) on the darwin x86_64,
darwin arm64 and windows x86_64 gates; Linux passed. Two reasons, both in
the harness:

- `Fiber::ExecutionContext::Parallel` starts its threads on demand
  (`wake_scheduler` starts one only when no thread is spinning or parked),
  so on a 3- or 4-core runner far fewer than 72 threads start, the table
  need not fill, and the 72 fibers share the threads that did start.
- The check sampled `on_fallback_cursor_set?` once per 256 operations of a
  worker; darwin arm64's in-stop run averaged 193 operations a worker, so a
  fallback thread could pass unseen (Windows' lazy run saw 4 samples,
  arm64's lazy one 69).

`claim_stress --fallback` now fills the table first: bare threads, one
allocation each, parked to the end, until one lands on the fallback (63
here: the main thread and the runtime's hold the rest). Every worker thread
started after that is on the fallback, however many the context starts.
The check counts allocations made on the fallback, read per allocation (a
fiber moves between the context's threads), and fails the run when the
fill never landed, when no allocation went through the fallback, or, lazy,
when no collection swept after the world. `make claim-stress` and the
overnight loops run `--workers=8 --fallback` in both arms. Locally both
arms pass with every allocation of all 8 workers on the fallback (657 712
and 477 665; 581 after-world sweeps in the lazy arm); the runner probe is
below.

## Files

- `diag/d21h.cr`, `diag/d21h-spec.diff`: the diagnostic and its changes to
  regression 21 (`ldiag_base_main.cr`'s `21b_` copy is the same against
  `../base`); `diag/latemover.cr`, `diag/fill.cr`: the two drivers.
- `move_main.cr`, `diag_main.cr`, `fmove_main.cr`, `ldiag_base_main.cr`,
  `ldiag_fix_main.cr`, `lmove_base_main.cr`, `lmove_fix_main.cr`: the
  entries (`./wt` the branch, `./base` `b339f533`); `build.sh`, `loop.sh`,
  `campaign.sh`.
- `runs/`: per-run summaries; the diagnostic's output for a passing base
  run (`dg122-4-d21.txt`), the failing late-mover base run
  (`ldg122-1-d21.txt`) and the fix (`ldgfix-1-d21.txt`); regression 109 in
  the three layouts (`r109-layouts.txt`); § 8's stress and mutant runs.
- `cs_campaign.sh`, `diag/fb_helper.cr`, `diag/mutation.txt`: § 8.
- `ab/`: `keep.py` output and the summaries of the five runs and the two
  `macos-latest` follow-ups.
