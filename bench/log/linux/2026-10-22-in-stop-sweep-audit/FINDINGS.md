# What the stop does to state a frozen thread is holding (2026-10-21/22)

Two bugs of one class had been found by random stress. Both were an in-stop
sweep rewriting state that a thread the stop had frozen *inside* a locked
section was halfway through updating: regression 75 (relink under a frozen
`map_chunk`) and regression 80 (dormancy under a frozen pool taker,
`bench/log/linux/2026-10-21-claim-counter-drift/`). This audit looks for the
rest by reading. It walks every mutator section that touches chunk, pool,
index, large-cache, cursor, dormant, freelist, release-queue or counter state,
and every step the collector takes inside the stop. For each pair it asks
whether a thread frozen at any instruction of the section breaks an
invariant. A stop suspends by signal (or `SuspendThread`), so it can land
anywhere in mutator code.

Branch `in-stop-audit-039`, written from `origin/release-0.39.0` at
`9157672e` and rebased onto `84a0259f` (the reproductions in this file ran on
the first, the checks below on the second; the rebase touched no file these
fixes do except `CHANGELOG.md` and `src/gcry/collect.cr`'s segv report). Local
host: QEMU x86-64 guest, 12 vCPU shared with other agents, Crystal 1.21.0.

Result: four real hazards beyond 75 and 80. Each is reproduced
deterministically with a research hook and fixed, and each has a regression
whose control arm restores the old code (81–84). Three more are real but only
move reporting counters, and they are left open (below). Everything else is
ruled out, with the reason in the table.

## Method

Two read-only inventories were cross-checked against the source:

- every mutator section, with its locks, its write order and the
  intermediate states a freeze leaves;
- every in-stop step, with what it reads and writes and which lock it takes.

Where they met, the question was whether the collector writes the same
state without the lock the mutator holds, or decides something (empty,
dormant, unmap) from a state the mutator is in the middle of changing. Each
"real" verdict below has a red control arm. Each "safe" verdict cites the
mechanism that makes it safe.

What runs inside the stop (`collect.cr` `run_collection_body`):

1. `stop_world_quiescing_roots`: Monitor gate, `@roots_lock`, finalizer
   lock, and every TLAB slot lock, all taken **blocking before** the
   signals, so no thread is frozen inside them.
2. `flush_all_tlabs`, `flush_all_alloc_batches`, `scrub_freelists`.
3. `clear_all_marks` / `clear_nursery_marks`.
4. `bitmap_settle_cursor_sets` and `mark_bitmap_alloc_in_flight`,
   `mark_large_alloc_in_flight`, then roots, stacks and the mark.
5. `enqueue_unreachable_finalizers`, `latch_sweep_mutator_count`.
6. With the sweep in the stop: `sweep(after_world: false)` and every callee,
   then the counter resets and `arm_page_barrier_after_*`.
7. `start_world`.

The incremental finishing slice (`collect_a_little`) runs 4 without the
settle, then 5–6.

The sweep runs inside the stop with `GCRY_DISABLE_LAZY_SWEEP=1`,
`GCRY_PAGE_DONTNEED=1`, `GCRY_TLAB=1`, the finishing slice of
`GCRY_INCREMENTAL=1`, or `lazy_sweep = false`. The stop itself, including the
settle and the barrier arm on a non-lazy major, always runs.

## The table

Locks: **CL** class freelist lock (`freelist_lock_ptr`, old or nursery),
**LL** `@chunk_list_lock`, **IL** `@index_lock`, **AL** `@alloc_lock`,
**slot** TLAB slot lock, **ab** allocation-batch slot lock.

| # | Mutator section (file) | Locks | What the stop does to the same state | Frozen inside: verdict |
|---|---|---|---|---|
| 1 | `map_chunk` publish: head read → header → `@chunks` store → `index_insert` (`heap.cr`) | LL → IL | Sweep relinks `@chunks`, queues empties, makes chunks dormant | **Safe since 75/80.** The sweep try-locks LL (`stop_list_held`). When the lock is held it relinks nothing, unmaps nothing, makes nothing dormant. |
| 2 | `map_chunk` after publish: `@heap_size += bytes`, then `note_mapped` (`heap.cr`, `collect.cr`) | none, then IL | Sweep `@heap_size = sat_sub(...)` (munmap branch). Bounds recompute takes **IL blocking** (`update_heap_bounds_after_unmap`) | `@heap_size`: **lost update, open (counters, below)**. IL: **hang, fixed (81)**. |
| 3 | `chunk_containing` locked path (free, realloc, `GC.size`, `is_heap_ptr`), `bitmap_indexed_chunk` | IL | Same blocking IL acquire in the in-stop sweep's bounds recompute | **Hang, fixed (81).** |
| 4 | `publish_large_growth` (`heap.cr`) | AL → IL | Same | **Hang, fixed (81).** |
| 5 | `index_insert` / `index_remove` / `index_reserve` / `index_ensure_cap` | LL → IL | In the stop the collector reads the index unlocked (`chunk_containing` under `@world_stopped`) and never inserts or removes (`index_remove` deferred to the flush; `make index-lock-wedge` counts 0 in-stop sections) | **Safe.** The sorted array is kept suspension-safe by store order (`index_insert_locked`); the radix is never shrunk. |
| 6 | `unlink_chunk`, `unlink_detached_large` | LL → IL | Sweep relink, large sweep | **Safe.** LL is held, so the relink is declined. The chunks unlinked are FREE large ones, which `sweep_large_one` skips. |
| 7 | `alloc_large` cache take, fresh path, `recycle_large_mapping`, `trim_large_cache`/`detach`, large `free`/`link_free_large` | AL (+LL/IL) | `sweep_large_one` in the stop never touches `@large_freelists`: it queues on `@pending_large_cache` | **Safe.** Mid-take headers are FREE (skipped). An all-zero header trips `sweep_large_uninitialised`. `@large_alloc_in_flight` is rooted. `recycle_large_mapping` refuses `@world_stopped`/`@collecting`. `@heap_size` / `@large_mapped_bytes` RMWs: see counters. |
| 8 | Bitmap hit path (`fast_alloc`), `cursor_advance_word`, `cursor_claim_word` | none (owner's slot) | Settle, mark, `sweep_words` (`occ = mark`) | **Safe.** The `in_flight` sentinel goes first, so the settle pins the set and premarks its claim. Claim order is mask → mark → occ. |
| 9 | `bitmap_alloc_locked` | CL | Same | **Safe** (sentinel, pin). |
| 10 | `bitmap_take_pool_chunk`: candidate check → CURSOR | CL, LL | Sweep dormancy | **Safe since 80** (one LL hold; dormancy declined while LL is held). |
| 11 | `bitmap_refill_pool` between take and `store_chunk` | CL | Sweep of a chunk CURSOR but in no slot | **Safe.** `live == 0 && cursor?` pins it (`sweep_small_bitmap`); the flush refuses CURSOR. |
| 12 | `retire_cursor_slot` (refill of an exhausted chunk): CURSOR cleared → chunk read → slot cleared | CL | Sweep finds the chunk empty and not CURSOR, queues it, flush unmaps it | **Use-after-unmap, fixed (82).** |
| 13 | `bitmap_revive_dormant`: find (LL) → AL {CURSOR, then ¬DORMANT} → zero `occ`/`mark` | CL, LL, AL | Dormant skip, sweep, flush | **Safe.** DORMANT until CURSOR is set, then CURSOR. `@dormant_chunk_bytes = sat_sub` is a plain RMW: see counters. |
| 14 | `oom_reserve_take_chunk` | CL + reserve lock | Sweep dormancy and unmap | **Safe.** Reserve chunks are never released (`reserve?` forces live). |
| 15 | `credit_cursor_set`: CAS on the credited mark, then the adds | none | Settle credits retired sets; `@bytes_since_gc.set(0)` | Attribution only: a delta claimed before the stop is added after the reset (next cycle's pacing). **Benign.** |
| 16 | Bitmap `free`: `occ &= ~bit` → `mark &= ~bit` → counters | CL, then none | Major: `clear_all_marks` + the trace's occ gate. Finishing slice: no clear, `occ = mark` | Major: **safe**. Finishing slice: the block is resurrected occupied with no owner. `live_objects` ends one low and `free_bytes` one payload high, and the block is held one cycle. **Open (counters, below)**. Reversing the order would let the slice reclaim it and the free then clear a bit a cursor may have re-claimed: worse. |
| 17 | Freelist pop `alloc_old_small_locked` / `alloc_nursery_locked`, free push `push_size_class_free`, `refill_size_class` head store, `refill_alloc_batch` (header layout `GCRY_BITMAP_ALLOC=0`, and every nursery chunk) | CL | `reclaim_small` links, `freelist_reserve_fully_dead`, `rebuild_size_class_freelist`, dormancy/unmap of a chunk found all FREE, `flush_all_alloc_batches` pushes | **Stale head stores, blocks on two lists, freelist installed into a dormant chunk. Fixed (84).** |
| 18 | `alloc_old_small_batched` stash pop | ab | `flush_all_alloc_batches` turns the stash into FREE nodes on the class list | **Double allocation, fixed (84 pop).** |
| 19 | `refill_alloc_batch` between CL release and the stash publish | none | Sweep reclaims the unpublished stash (USED, reachable only through headers) | **Double allocation, fixed (84 publish).** |
| 20 | `revive_dormant_chunk` / `install_revived_chunk` (header) | CL, LL, AL | Dormant skip | **Safe** (DORMANT flipped last, under AL). |
| 21 | TLAB `tlab_alloc_small`, `tlab_free_small`, install | slot | `flush_all_tlabs` | **Safe.** Slot locks are taken blocking before the stop. |
| 22 | `tlab_refill_locked` | AL | Flush, scrub, sweep rebuild, dormancy of a detached batch's chunk | **Safe.** The TLAB epoch check discards the refill and requests a rebuild (`discard_refill_across_collection`). |
| 23 | `add_root` / `delete_root` / realloc pin; finalizer registry | roots lock; finalizer lock | Root scan, `enqueue_unreachable_finalizers` | **Safe.** Taken blocking before the stop. |
| 24 | `cursor_set_under_lock` (thread's first allocation) | `@cursor_lock` | Settle walks sets | **Safe.** A set is counted with no chunks; the settle credits and retires it. |
| 25 | Chunk flag writes (`set_cursor`, `set_dormant`, `set_idle`, …) | — | Sweep writes IDLE/HOLED/SPARSE/DORMANT/PINNED | **Safe.** `update_flag` is an atomic OR/AND (`block.cr`). |
| 26 | mprotect barrier SEGV handler (`mprotect_fault`): read the card state → set dirty → clear protected → `mprotect(RW)` | none (signal handler) | In-stop arm (`arm_page_barrier_after_*`): disarm, free the card state, re-protect | **Use-after-free and a lost barrier write, fixed (83).** |
| 27 | Thread list births/deaths | `Thread.lock` | Settle, latch, stack scans | **Safe.** The collector holds `Thread.lock` across the stop (`linux_stw.cr`). |
| 28 | Counters: `@heap_size` (`map_chunk`, outside any lock), `@dormant_chunk_bytes` (revive, CL or AL), `@expl_freed_bytes_since_gc` (`note_explicit_free`, none) | none / CL / AL | Sweep `sat_sub`/`+=`/`= 0`; post-sweep `= 0` | **Lost updates, open:** reporting counters (below). `live_objects`/`free_bytes`/`bytes_since_gc` are atomic on the bitmap heap (`counters_atomic?`); the plain arm is the header layout's or `debug_plain_counters`. |

## The four fixes

### 81: the in-stop sweep took `@index_lock` blocking (hang)

`Heap#sweep` ends with `update_heap_bounds_after_unmap` when its munmap
branch queued a chunk (`any_drop`). That function takes `@index_lock` with
`sync`. Any thread the stop froze inside an IL section (row 3) never lets
go, so the collector spins with every mutator parked. The `index_remove` a
few lines up had been moved out of the stop for this exact reason, but this
call had not. `make index-lock-wedge` counts only insert/remove sections, so
it never saw it. The recompute did nothing useful there either: it reads the
bounds off the index, and the dropped chunks stay indexed until the flush.

**Fix (`9b72182e`):** no recompute in the sweep. `flush_pending_empty_chunks`
recomputes after the release, with the world running, so the bounds now
shrink by the released chunks as well. Knob `stop_sweep_index_lock = false`
is the control arm.

**Reproduction (`process_spec/regression/81`):**

- Setup: a thread spins inside `@index_lock`. The main thread allocates
  nothing after that point, because a first allocation of a class maps a
  chunk and would wait on the lock. It then collects with
  `lazy_sweep = false`, `parallel_empty_chunk_munmap = true` and one empty
  chunk.
- Fixed arm: the stop ends while the holder still holds the lock. The empty
  chunk leaves the index after the holder lets go.
- Control arm: hangs. The parent kills the child at 20 s, and the watchdog
  reports `STOP-THE-WORLD STALLED 1000 ms in phase=sweep` while the holder
  sits in `sigsuspend` (`red/81-control-index-holder-stall.log`).
- Locally the fixed arm passed and the control arm hung in the spec run, and
  the control child hung again run on its own (the log above).

**Reach.** It needs a sweep inside the stop that unmaps empties while another
mutator exists. `munmap_empty_chunks_this_collect?` is true for a
single-mutator latch (at most two counted threads) or with
`parallel_empty_chunk_munmap`. On a default execution-context build, main
plus the Monitor already count two, so a third thread makes the latch
multi-mutator. There the hang needs `parallel_empty_chunk_munmap`, which is a
library/spec property; its own comment says it "could hang". [INFERENCE] A
build without the Monitor thread (main plus one worker) reaches it under any
in-stop knob.

### 82: a cursor retire left a chunk the stop could unmap under its owner

A refill that exhausts its chunk retires it (`retire_cursor_slot`). It cleared
CURSOR, then read the chunk (`bitmap_pool_candidate?`,
`bitmap_capacity_changed`), then cleared the slot.

- Frozen after the first step, the chunk is no cursor's. The in-stop sweep
  honours CURSOR and nothing else: it cannot take the class lock, and the
  finishing slice runs no settle. The settle's PINNED is read only by the
  after-world sweep.
- So a chunk whose blocks had all died was queued for release. The flush
  saw no `occ` and no CURSOR and unmapped it after `start_world`.
- The owner resumed into the unmapped header. Its slot also still named the
  chunk, and a later settle would write PINNED into it.

**Fix (`601bb973`):** read everything while the chunk is CURSOR, clear the
slot, and clear CURSOR last, with nothing touching the chunk afterwards.

- The capacity version is bumped by slot index, computed beforehand.
- Frozen before the CURSOR clear, the chunk is CURSOR in no slot. The sweep
  keeps that, as it keeps a just-taken chunk (row 11).
- Cost: whether to publish capacity is decided before the clear. A free in
  that window published its own; a pool that missed both finds the chunk at
  the next bump of the class.
- Knob `cursor_retire_slot_first = false` is the control arm.

**Reproduction (`process_spec/regression/82`):**

- `cursor_retire_hook` runs right after the CURSOR clear. It frees the
  chunk's blocks with the body of `GC.free`, because the thread holds the
  class lock, then parks until the main thread has collected (sweep in the
  stop, munmap) and the flush has released the chunk.
- Fixed arm: the chunk is out of the index, no slot names it, the thread
  resumes, and drift is 0.
- Control arm: the chunk is out of the index while the parked thread's slot
  names it. The child exits there.
- With the control resumed instead (a scratch copy of the spec), the child
  dies 3 of 3: `SIGSEGV at 0x…010 — inside the heap span but in no live
  chunk`, at `retire_cursor_slot_cursor_first` reading `chunk.value.size_class`
  (`red/82-control-resumed-retire-*.log`).

### 83: a stop could freeze the mprotect barrier's fault handler

The handler ran with the stop's suspend signal deliverable. Frozen between
reading `@@mp_state` and its `mprotect(RW)`, it met a stop whose non-lazy
major re-armed the barrier in the stop:

- `disarm_mprotect_barrier` retired the card state, and
  `mprotect_set_heap_range` called `clear_mprotect_cards` again, which freed
  what had just been retired. The handler resumed into freed memory.
- The handler then made the page writable under fresh cards that called it
  protected and clean, so writes to it went unrecorded until the next arm.

**Fix (`6323afc7`):** `SIG_SUSPEND` is in the handler's `sa_mask`. The
handler takes no lock and makes one syscall, so the stop waits that long.
Knob `Platform.mprotect_block_suspend = false` is the control arm.

**Reproduction (`process_spec/regression/83`, Linux):**

- `prefer_mprotect_barrier`, `incremental_auto`, `lazy_sweep = false`.
  `mprotect_fault_hook` parks one thread's write fault on a protected block.
  The main thread widens the heap span, so the new card state is not
  malloc's recycled old one, and collects.
- Fixed arm: no stop ends inside the handler (the stop waits up to the
  hook's 2 s), and a later write to the page is in the current cards' dirty
  bits.
- Control arm: a stop ends inside the handler. On resuming, the handler's
  atomics hit the freed card state: SIGSEGV inside the SIGSEGV handler, and
  the process dies (exit 139, 3 of 3 runs; `red/83-*`). The spec also
  accepts the other form: where malloc keeps the freed block mapped, the next
  write is in no dirty bit. That form was not observed with the widened span.
- Before the span was widened, the control read the write as recorded,
  because malloc handed the freed block back as the new card state.

**Reach.** The mprotect backend is selected when soft-dirty does not work,
which is aarch64 Linux, where the kernel lacks soft-dirty [INFERENCE], or
when `GCRY_MPROTECT_BARRIER=1`. It is armed only with a nursery or
incremental marking (`GCRY_INCREMENTAL=1`). Default headerless builds arm
nothing.

### 84: the stop wrote freelists a frozen thread was inside (freelist layout)

On the header layout with `GCRY_BITMAP_ALLOC=0`, and for every nursery chunk,
the in-stop collector writes class freelists without the class lock, which
it cannot wait on. These are rows 17–19. A thread frozen inside one stores
what it read when it resumes:

- a stale head over the sweep's pushes and rebuilds;
- a popped block the rebuild has linked again;
- the freelist of a chunk it had laid out as FREE blocks, which the sweep
  found empty and made dormant or queued for unmap (the header form of 80);
- a batch stash the flush turned into FREE nodes (`alloc_old_small_batched`);
- a stash the sweep reclaimed before the slot held it (`refill_alloc_batch`
  between the class lock and the publish).

**Fix (`05001dc1`):**

- `note_frozen_freelists`, inside the stop before the flushes, tries every
  class lock and gives each free one straight back. A frozen holder cannot
  release before the world restarts, so a held lock means a frozen thread is
  inside for the whole stop. Holding the free ones would hang a collector
  hook that allocates against the rule.
- Those classes are frozen for the stop:
  - their freelist chunks are not swept (all live, kept,
    `stop_sweep_freelist_declined`);
  - their rebuild requests carry over;
  - `flush_all_alloc_batches` leaves their stashes alone. It also tries each
    batch slot's lock and freezes the classes of a held slot's stash, so
    those stashes are not reclaimed.
- `refill_alloc_batch` publishes its stash before releasing the class lock,
  in the existing lock order (freelist → batch slot).
- Bitmap chunks are not touched. Their protocol is the settle's, and the
  probe is skipped on a heap with no freelist chunks: headerless, no
  nursery.
- Knobs: `stop_freelist_try_lock = false` and
  `alloc_batch_publish_locked = false` are the control arms.

**Reproduction (`process_spec/regression/84`, three windows × two arms,
skipped on a heap without freelist chunks):**

- *refill*: `refill_publish_hook` parks a refill between laying the chunk
  out and storing the head. The main thread collects with a dormant budget.
  - Fixed arm: the chunk stays awake, and the block's stamps survive another
    collection.
  - Control arm: the thread allocates from the chunk the stop made dormant.
    After one more collection both stamp words read `0x0`, 3 of 3
    (`red/84-control-refill-stamps.log`).
- *pop*: `alloc_batch_pop_hook`.
  - Control arm: the block handed out is also on the class list.
- *publish*: `alloc_batch_publish_hook`, batch 32.
  - Control arm: blocks in the thread's stash are also on the class list.
- Every arm ran green 3 of 3 under `GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0` on
  `-Dgcry_block_headers`.

### 84 after review: a lock-order deadlock and the after-world sweep

A review of the branch (`agent://AuditReview`) found two blockers in the
first version of 84, both confirmed here red→green by new arms of
regression 84 (now six windows × two arms):

- **Lock order.** Publishing the stash under the class lock made
  `refill_alloc_batch` take class → batch slot, while
  `with_small_allocation_excluded` (the world-running page release of
  `GCRY_PAGE_DONTNEED=1` / `GCRY_MOSTLY_EMPTY=1`) took every batch slot,
  then the class lock. Fix (`9dbff29f`): TLAB slots, then the class lock,
  then the batch slots. No other path holds a batch slot while taking a
  class lock (`alloc_old_small_batched` lets its slot go before it refills;
  the stop only try-locks). *exclusion* arm: a refill parks under the class
  lock before its slot, a second thread runs the exclusion, the refill
  goes on. Fixed: both finish. Control (`small_exclusion_batch_first`): the
  two threads wait on each other, the child reports it after 5 s and exits.
- **The after-world sweep.** The stash a flush keeps (slot lock held: the
  owner frozen in a pop) or a refill frozen under the class lock publishes
  after the stop is USED, unmarked and linked only through headers. The
  in-stop sweep skips its class, but the after-world sweep — the default
  for a multi-mutator heap with TLAB off — takes only the chunk's class
  lock, found the blocks unmarked once the owner let go, and put them on
  the class list while the stash still linked them: the next pop from each
  hands the same block out. Fix (`580cca6a`): a stop that found any frozen
  freelist class sweeps in the stop, where those classes are left alone
  (`sweep_frozen_classes_in_stop?`, counted in
  `stop_frozen_sweeps_in_stop`). Rare — a thread frozen in a few
  instructions under a class lock — and it costs that one collection the
  sweep's pause. Marking the kept stash after `clear_all_marks` would not
  cover a refill's claimed-but-unpublished stash, which is in its registers
  only. *pop-lazy* and *publish-lazy* arms: the batch windows with
  `lazy_sweep = true` and two idle threads. Fixed: no held block on the
  class list, the sweep moved into the stop. Control
  (`stop_frozen_sweep_in_stop = false`): held blocks on the class list.

And a nit on 82: a signal fence before the CURSOR clear in
`retire_cursor_slot` (`6bbca28c`), as `cursor_claim_word` has, so the
compiler cannot move the relaxed RMW above the slot stores. No arm: there is
no way to make the compiler hoist it on demand.

## Open: reporting counters (not fixed)

None of these feeds collection triggering or pacing. Those follow
`bytes_since_gc` and the sweep's own walk. Each is a plain read-modify-write
that a thread frozen between its load and its store overwrites with a stale
value after the stop:

- `@heap_size`: the in-stop munmap branch `sat_sub` against `map_chunk`'s
  unlocked `+=`. It is also racy between mutators, since `map_chunk`'s `+=`
  sits outside the list lock. `GC.stats.heap_size` reads high after such a
  race.
- `@dormant_chunk_bytes`: the sweep's reset and recount against a revive's
  `sat_sub` under the class lock. A stale store can zero it, and
  `flush_pending_dormant_chunks` returns early on zero, so dormant pages go
  back one cycle late (RSS only).
- `@expl_freed_bytes_since_gc`: the post-sweep `= 0` against `+=` with no
  lock (`GC_get_prof_stats`).
- Row 16, the bitmap free in the finishing slice: `live_objects` one low and
  `free_bytes` one payload high per event, and the block is held one cycle.
  No reuse hazard, because the block stays occupied.

Found in passing, not reproduced: [INFERENCE] the same double
`clear_mprotect_cards` frees the retired card state with the world running
when the barrier is re-armed after a lazy sweep, so a handler running on
another CPU at that moment reads freed memory. 83 closes only the in-stop
freeze.

## Checks and stress after the fixes

All on the branch rebased onto `origin/release-0.39.0` at `84a0259f`. Each
heavy run held the shared lock, one at a time, bounded by
`bench/run_bounded.sh`:

| check | result |
|---|---|
| `crystal tool format --check src spec process_spec bench samples` | clean |
| `make lint` | 237 inspected, 0 failures |
| `crystal spec -Dgc_none spec/all_specs.cr` | 296 examples, 0 failures |
| `crystal spec -Dgc_none process_spec` | 240 examples, 0 failures |
| `GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none -Dgcry_block_headers process_spec` | 241 examples, 0 failures |
| `make windows-typecheck`; `--cross-compile --target aarch64-apple-darwin` `--no-codegen` | clean |
| `make claim-stress` (lazy, then `GCRY_DISABLE_LAZY_SWEEP=1`; seed 1) | both arms: drift 0, refused 0, unlisted 0, `dormant_held=0` |
| `make chunk-list-drift` | ok: 0 stranded over 36 765 mappings, window 0 of 300 (299 of 300 without the splice) |
| `claim_stress --seconds=5 --workers=4`, release, `GCRY_DISABLE_LAZY_SWEEP=1 GCRY_SEGV_REPORT=1`, seeds 1001–1100 | **100 of 100 clean** (exit 0, every drift 0, `stress/instop100.txt`) |

After the review fixes (on `580cca6a`), each heavy run under the shared lock:

| check | result |
|---|---|
| regression 84, all 12 arms (`GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0`, `-Dgcry_block_headers`) | 3 of 3 runs, 24 examples, 0 failures |
| the deadlock configuration: `stw_mt_property_test` release, header layout, `GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0 GCRY_ALLOC_BATCH=8`, alternating `GCRY_PAGE_DONTNEED=1` / `GCRY_MOSTLY_EMPTY=1`, 60 iterations, workers 2,4, seeds 3001–3050, `run_bounded.sh 120` | 49 of 50 pass; run 11 (`GCRY_MOSTLY_EMPTY`, seed 3011) exit 3, the Crystal Parallel-scheduler deadlock (crystal-lang/crystal#17486: threads in `Scheduler#resume`, `parallel/scheduler.cr:97`; `stress/deadlock-run11-scheduler-17486.log`); no gcry stall (`stress/deadlock50.txt`) |
| `make bitmap-marks-freelist` | ok (331 and 253 examples, 0 failures; the `GCRY INVARIANT FAILURE` line in its log is `spec/invariant_spec.cr`'s deliberate drift) |
| header `process_spec` (`GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0 -Dgcry_block_headers`) | 253 examples, 0 failures |
| `crystal spec -Dgc_none process_spec` | 252 examples, 0 failures |
| format, `make lint`, `make windows-typecheck` | clean |
