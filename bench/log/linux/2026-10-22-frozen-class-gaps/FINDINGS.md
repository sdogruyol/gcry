# The frozen-class gaps regression 84 left (2026-10-22)

The in-stop audit (`../2026-10-22-in-stop-sweep-audit/FINDINGS.md`,
regressions 81–84) and its review left three items open. This closes them:

1. `GCRY_TLAB=1` on the freelist allocator: `flush_all_tlabs` and
   `scrub_freelists` wrote the lists of a class a frozen thread was inside.
2. No stop of an incremental cycle flushed allocation-batch stashes, and
   none flushed TLABs either. The finishing slice sweeps inside its stop.
3. A bitmap `free` frozen between its `occ` and `mark` clears across the
   finishing slice. It is now fixed rather than documented.

Each is forced by a hook or a split of the mutator section, with a control
arm that restores the old code: `process_spec/regression/85_frozen_class_gaps_spec.cr`,
four windows × two arms.

Branch `frozen-class-gaps-039`, from `origin/release-0.39.0` at `32ce703a`.
Local host: QEMU x86-64 guest, 12 vCPU shared with other agents, Crystal
1.21.0. Every heavy run held `/home/naruto/playground/.scratch/heavy.lock`.

## 1. TLAB flush and scrub under a frozen class-lock holder

**Reading.** `note_frozen_freelists` tries every class lock inside the stop
and freezes the classes whose lock is held: the in-stop sweep leaves their
chunks unswept, and `flush_all_alloc_batches` leaves their stashes alone.
`flush_all_tlabs` and `scrub_freelists` (`src/gcry/tlab.cr`) did not consult
the masks. They spliced every TLAB chain onto `@freelists[c]` /
`@nursery_freelists[c]`, and they rewrote any list holding a USED node.

**Who holds a class lock with TLAB on.** The TLAB paths do not take it: the
hit path takes the slot lock, and the refill takes `@alloc_lock`. Three
paths do:

- an allocation that reads `@world_stopped` true goes to `tlab_bypass`, i.e.
  `alloc_old_small` / `alloc_nursery` under the class lock. This is the
  collector itself, or a thread the stop missed in its birth window.
- an allocation or a `free` that read `@tlab_enabled` false before a runtime
  `tlab_enabled = true` takes the class-list path.
- a page release (`with_small_allocation_excluded`) takes it, but only on the
  collector's own post-stop path, which no stop can freeze.

A thread frozen inside one of these has the list head (or a `next_free`) in
hand and stores it when it resumes. Anything the stop put in front of that
head is lost. [INFERENCE] Without the runtime switch, reaching this takes a
thread that ran through one stop and was frozen by the next while still
inside the class section. That is a narrow window, but nothing closed it.

**Reproduction (*tlab-flush*).** The main thread's TLAB holds a chain of
three blocks of the 1792-byte class. TLAB is switched off, and a second
thread allocates the class until its refill parks in `refill_publish_hook`
under the class lock, with the chunk laid out and the head store still to
come. TLAB goes back on, and the main thread collects (`GC.collect`, so the
sweep runs in the stop under TLAB).

- Control (`stop_tlab_flush_frozen_skip = false`): the flush splices the
  main thread's chain onto the class list, and the refill then stores its
  own head over it. All three blocks end in no TLAB and on no list: FREE
  blocks nothing hands out (`frozen85: the control arm went wrong: 3 TLAB
  blocks in no TLAB and on no list`).
- Fixed: the chain stays in the TLAB (`stop_tlab_flush_frozen_kept` moves),
  and none is stranded.

The control arm shows lost blocks, not blocks handed out twice. [INFERENCE]
The scrub's half has a sharper form: a frozen pop holds `h` and
`n = h.next_free` while the scrub rebuilds the list in reverse. The pop then
installs `n`, whose `next_free` now points back at `h`, the block it
returned. The TLAB refill skips a USED node, so that form is mostly
self-healing. It is not separately forced. The same mask and the same knob
cover it.

**Fix (`5906ca1e`).** `flush_all_tlabs` leaves a frozen class's chains in
their TLAB, and `scrub_freelists` leaves a frozen class's lists alone. A
kept chain is safe. Its blocks are FREE in chunks the in-stop sweep does not
sweep in this stop (frozen class), so nothing links, rebuilds or releases
them, and the owner keeps handing them out. The next stop that finds the
lock free flushes the chain. Knob: `stop_tlab_flush_frozen_skip`. Counter:
`stop_tlab_flush_frozen_kept`.

## 2. The incremental cycle never flushed stashes or TLABs

**Reading.** Only `run_collection_body` calls `flush_all_tlabs` /
`flush_all_alloc_batches` / `scrub_freelists`. Neither `begin_incremental`
nor any `collect_a_little` slice calls them. The finishing slice sweeps
inside its stop (`sweep(major: true)`), on the cycle's marks.

- **Stash.** A stash claimed before the cycle began is USED and unmarked.
  `clear_all_marks` at the begin stop clears whatever it had, and
  allocate-black marks only what is claimed or popped while marking. It is
  linked only through its headers. The finishing sweep reclaims it onto the
  class list while the slot still links it, so the next pop from the slot
  and the next pop from the list hand out the same block.
- **TLAB.** A chain is FREE and on no list. When the sweep releases an empty
  chunk of the class, it rebuilds the class list from every FREE block of
  the chunks it kept (`rebuild_size_class_freelist`), and that includes the
  chain. The chain is then on the list and in the TLAB at once. [INFERENCE]
  A chunk that holds nothing but chain blocks, and not the chain's head,
  is found empty and made dormant under the TLAB.

**Reproductions.**

- *slice-stash*: a thread's first allocation of the class claims a batch
  of 8 and keeps one block. The thread exits, and its stash of 7 stays in
  the slot. A whole cycle runs (`collect_a_little` until it returns true,
  with the mprotect barrier as in regression 83). Control
  (`inc_finish_flush = false`): stash blocks are on the class list. Fixed:
  the slot is empty.
- *slice-tlab*: 200 blocks of the class are held across several chunks,
  and `GC.collect` empties every TLAB. A thread then refills its TLAB of the
  class, keeps its block and exits, and the 200 are dropped. A whole cycle
  runs. The sweep makes the two all-dead chunks dormant and rebuilds the
  class. Control: chain blocks are on the class list. Fixed: the chain was
  flushed first.

**What made the first versions pass on the control.** Three things, written
down here so the next window does not repeat them:

- **The spec's own pointer arrays.** `frozen85_stashes(...).empty?` built an
  array of every stash address. That array is a conservative root, so every
  stash block was marked and none reclaimed. The windows now count chains
  before the cycle (`frozen85_*_count`, `@[NoInline]`) and list them only
  after it.
- **HOLED chunks.** The chain's head pointer sits in the heap's own memory,
  which the trace scans, so the head is marked. A FREE+marked block counts
  its chunk live (the discover pass). A chunk whose only marks are on FREE
  blocks is HOLED with no live page, and the rebuild relinks nothing from
  it. The thread's kept block gives the chain's chunk a live page.
- **Slices driven by allocation.** While a cycle is open, every allocation
  runs a slice (`maybe_collect`). The *bitmap-free* window's `Thread.new`,
  made after the cycle began, finished the cycle before the free parked.
  Threads are now made before the cycle, and nothing allocates inside it.

**Fix (`9d965d09`).** Before its sweep, the finishing slice runs
`note_frozen_freelists`, `flush_all_tlabs`, `flush_all_alloc_batches` and
`scrub_freelists`, in the order a stop-the-world collection uses. The TLAB
slot locks are already held by `stop_world_quiescing_roots`. A frozen
class's stash and chains stay put, as in that stop, and so do its chunks.
The begin stop needs no flush: anything claimed during marking is marked,
and the finishing stop flushes whatever is left. Two details:

- A stash block claimed while marking is marked. After the flush it is FREE
  and marked, which the discover pass counts as live for this cycle, so its
  chunk is not released until the next one.
- Knob: `inc_finish_flush`.

## 3. A bitmap `free` frozen between its two clears

**Reading.** The bitmap arm of `free_result` holds the class lock across
`bitmap_free_block`: `occ &= ~bit`, then `mark &= ~bit`. If the finishing
slice freezes it between the two, the block is `occ=0, mark=1`. The mark
came from the trace or from allocate-black. The slice's kernel sets
`occ = mark` (`sweep_words`) and the block is occupied again, owned by
nobody. The free resumes and subtracts it from `live_objects` and adds it
to `free_bytes`. The next sweep finds it unmarked and does both again. A
stop-the-world major is safe: it clears every mark before it traces, and
the trace's `occ` gate marks nothing unoccupied.

**Measured.** In the *bitmap-free* control (default layout), after three
more `GC.collect` calls `live_objects` stays one below the walked count
(`count_live_blocks`): reported 163/164/160 against walked 164/165/161. The
fixed arm reads 159/159, 160/160 and 157/157. So the drift is permanent,
not one cycle long. The block itself is out of use for one cycle.

**Fix vs document.** The audit had left it as counters-only, because
reordering the two clears lets the slice reclaim the block. A cursor can
then claim the bit lock-free (`cursor_advance_word` on the hit path), and
the stale `occ` clear clobbers that claim. Any change inside the free has
that problem, or costs a store on the default `free` path. The fix is on
the collector's side instead, and only in the finishing slice:
`clear_frozen_bitmap_stray_marks` (`9d2e504b`).

- It tries the class lock of each bitmap class, which is 40 try-locks.
- If one is held, it walks that class's bitmap chunks through the index and
  clears `mark & ~occ` before the sweep.

With every mutator frozen, a marked bit with no occupancy is one of three
states:

- the frozen free. Clearing it is the fix.
- a claim release (`cursor_release_claim`) between the same two clears.
  Clearing is right here too.
- a claim between its `mark` OR and its `occ` OR (`cursor_claim_word`).
  Cleared, the sweep leaves the bits free, and the owner's own OR completes
  the claim. The chunk is its CURSOR, no sweep runs before the next stop,
  and that stop's settle premarks the claim again.

The trace marks nothing with `occ` clear, so nothing live is touched.

The default path is unchanged:

- the `free` is not touched;
- the sweep kernel is not touched;
- a stop-the-world collection does nothing new;
- the finishing slice exists only with `GCRY_INCREMENTAL=1`.

**Reproduction (*bitmap-free*, bitmap allocator, Linux).** The spec
reenacts the bitmap arm of `free_result` step by step: same lock, same
`set_free`, same two atomics. It yields between the atomics, so the thread
parks there. (A hook inside `bitmap_free_block` would put a load and a
branch on the default free path.)

1. The block is rooted in static data.
2. `collect_a_little(1)` runs the begin stop, which marks the block (checked:
   `occ` and `mark` set).
3. The free parks.
4. The cycle finishes.
5. The free completes.

Control (`stop_slice_stray_mark_clear = false`): the block is occupied
afterwards. Fixed: it is free, and `stop_slice_stray_marks_cleared` moved.

## Regression 85

`process_spec/regression/85_frozen_class_gaps_spec.cr` (`a22d646a`). Each
arm runs in a child process.

- A child that cannot reach its window prints
  `frozen85: this heap cannot reach the window, skipped` and passes. That
  covers the wrong allocator, and no page barrier for the incremental
  windows (Linux only, mprotect as in 83).
- The parent then does not ask for the control's mark. Everywhere else it
  requires `frozen85: the control arm went wrong`.

Local, three runs of the whole file per layout, each 16 examples, 0
failures:

| layout | runs | skipped |
|---|---|---|
| header + freelist (`-Dgcry_block_headers`, `GCRY_BITMAP_ALLOC=0`) | three | *bitmap-free* |
| header (`-Dgcry_block_headers`) | three | all but *bitmap-free* |
| default | three | all but *bitmap-free* |

All three controls that run on header + freelist go red, and *bitmap-free*
goes red on the other two.

## Stress after the fixes

`bench/stw_mt_property_test.cr` built `--release`, each run
`run_bounded.sh 120`, `--iterations=40 --workers=2,4`, seeds 3001–3150, one
run per lock hold (`stress/run.sh` in the agent's scratch):

Arms: header + freelist (`GCRY_BITMAP_ALLOC=0`) plain, `--tlab --nursery`,
`GCRY_ALLOC_BATCH=8`, `GCRY_INCREMENTAL=1 GCRY_ALLOC_BATCH=8` and
`GCRY_INCREMENTAL=1 --tlab`, plus the default layout with `GCRY_INCREMENTAL=1`.

**Incomplete.** When this file was committed, only 9 of the 150 seeds per
arm had run: about 2 per arm at 200 iterations, plus a first 9 at
40 iterations. All of them passed (exit 0, no stall). Each run takes about
1 s. The wait for the shared lock between runs is what limits the rate.
The ≥150-run requirement is still open. The loop keeps running in the
agent's scratch (`stress/results.txt`).

## Found in passing, not reproduced

- [INFERENCE] The bitmap `free`'s `mark` clear can wipe a concurrent
  claim's mark, with the world running. Between the free's `occ` clear and
  its `mark` clear, the chunk's cursor owner can advance lock-free into that
  word (`cursor_advance_word` on the hit path) and claim the freed bit. If a
  sweep can run before the next stop (after-world lazy sweep pending, or
  incremental marking), the claim marks it, and the free's `mark` clear then
  removes that mark. The sweep's `occ = mark` takes the block out from under
  the claim, so the cursor hands out a block that is free in `occ`, and a
  second claim can hand it out again. The window is the gap between two
  adjacent atomics on one thread, widened only by preemption. This predates
  the branch and is not changed by it.
