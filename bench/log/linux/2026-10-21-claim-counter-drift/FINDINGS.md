# The in-stop sweep made a chunk dormant under a thread taking it (2026-10-21)

The overnight stress of `release-0.38.0` at `8b9e7eab` failed 1 of 100
in-stop runs with walk-against-counter drift and no broken stamp. It looked
like accounting, but it isn't. A stop that freezes a thread between
checking a pool chunk and taking it can make that chunk dormant. The
thread then takes the dormant chunk and allocates into it. Every later
collection releases the chunk's pages under the live objects in it, so on
Linux they read zero. No sweep reclaims the chunk, and the next revive
hands its blocks out again. The counters keep its blocks while every walk
counts the chunk empty, and that's the drift the harness saw. The bug is
older than the occupancy claim: 0.37.0 has it, in the same configurations.
The default after-world sweep never had it.

Branch `claim-drift-038`, from `origin/release-0.38.0` (`8b9e7eab`). All
local: QEMU x86-64 guest, 12 vCPU shared with the overnight stress (about 8
busy), Crystal 1.21.0. Every loop is `claim_stress --seconds=5 --workers=4`
under `bench/run_bounded.sh 60`, one process at a time, release builds,
`GCRY_SEGV_REPORT=1`, and `GCRY_DISABLE_LAZY_SWEEP=1` for the in-stop arm.

## The failure

```
claim_stress seconds=5.0 workers=4 seed=1038 ring=512 lazy_sweep=false headers=false
  refused_frees=0 live_objects_drift=-1632 free_bytes_drift=130560 unlisted_chunks=0
  FAIL: walk against counter drifted (live -1632, free bytes 130560)
```

Drift is walk minus counter (`Invariant.live_objects_drift`,
`free_bytes_drift`). 1632 blocks of 80 bytes is exactly one class-4 chunk:
headerless, 128 KiB, 26 bitmap words, `data_offset` 448. The counters held a
full class-4 chunk that the walks counted empty. The harness never
allocates 80 bytes itself. Class 4 holds Crystal's `select` actions
(`Channel::StrictReceiveAction`, `Channel::SendAction`, 80 bytes each,
`instance_sizeof`): one per `select`, never freed explicitly, never stamped.
That is why no stamp broke.

## Rate before

| tree | build | arm | runs | failed |
|---|---|---|---|---|
| `8b9e7eab` | release | in-stop, seeds 1001–1100 (overnight, reported) | 100 | 1 (1038) |
| `8b9e7eab` | release | in-stop, seeds 1001–1112 (here) | 112 | 1 (1073) |
| `8b9e7eab` + counters (`instr-widen-8b9e7eab.patch`, `WIDEN_NS=0`) | release | in-stop, seeds 1001–1042 | 42 | 0 |

Seed 1073 is the same bug, caught in a class that is stamped
(`red/base-8b9e7eab-stop-seed1073.log`). The drift was live −2698 and
+129 504 free bytes: 2698 blocks of 48 bytes, 17 short of a full class-2
chunk (2715 blocks). The run also broke stamps: 33 checks of 9 live 32-byte
atomic blocks (33 bytes with the atomic slack, so class 2, flags `ATOMIC`)
read `0x0 0x0 last 0x0`, and `live?` still answered true. [INFERENCE] That
is the dormant flush's `MADV_DONTNEED` under their owner, as in the widened
runs and regression 80 below. Class 2 also holds the harness's 36-byte
check messages (`"worker N before release"`, atomic).

The overnight debug and `GCRY_DEBUG_INVARIANTS=1` runs were clean, and
that's expected. The window is a few instructions long, and the invariant
checker declines whenever the heap has other mutator threads
(`concurrent_mutators?`), which here is the whole run.

## Root cause

`Heap#bitmap_take_pool_chunk` (`src/gcry/bitmap_alloc.cr`) takes a chunk in
one hold of `@chunk_list_lock`, under the class lock:

```crystal
with_chunk_list_for_allocation do
  if chunk = bitmap_indexed_chunk(address)
    if chunk.address == address && bitmap_pool_candidate?(chunk, index, atomic)
      ChunkHeader.set_cursor(chunk, true)
      return chunk
```

`bitmap_pool_candidate?` accepts a chunk that isn't dormant, has no
cursor on it and has a free block. Between that check and `set_cursor` the
chunk belongs to nobody: it isn't CURSOR yet and isn't in any slot, so the
settle doesn't pin it (`bitmap_settle_cursor_sets` pins only the chunks in
slots).

In the stop, `Heap#sweep` (`src/gcry/collect_sweep.cr`) takes the list lock
without waiting. When a frozen thread holds it (`stop_list_held` false,
`list_relinkable` false), the sweep leaves the list alone and doesn't queue
empties for unmap (`elsif munmap_empty_chunks_this_collect? &&
list_relinkable`). That was 272d73e5, regression 75. The dormant branch just
above it (`elsif can_dormant`) had no such gate. So, with a sweep inside the
stop:

1. Thread A, under its class lock and the list lock, finds chunk X a
   candidate: a few free blocks, or all of them.
2. A stop freezes A there. The mark finds nothing live in X, the sweep finds
   X empty and not CURSOR, and `can_dormant` (a multi-mutator `GC.collect`'s
   `parallel_release_on_collect?`, or a dormant budget) sets DORMANT.
3. The world restarts, and the post-stop flush DONTNEEDs X's pages.
4. A resumes, sets CURSOR on X, claims its words and allocates into it.
   Each allocation is credited to `live_objects` and taken from
   `free_bytes`.

From there X is a cursor's chunk and a dormant one at the same time. Every
reader of DORMANT treats it as an empty chunk:

- **Walks**: `Invariant.count_live_blocks` skips a dormant chunk, and
  `count_free_bytes` counts all of it free. That is the drift: minus the
  blocks still in X, plus their bytes.
- **Sweep**: the top of `Heap#sweep` skips dormant chunks. X's garbage is
  never reclaimed, so the class-4 chunk of dead `select` actions stayed
  full in the counters, all 1632 blocks.
- **Flush**: `flush_pending_dormant_chunks` releases the data pages of
  *every* dormant chunk after *every* collection (Linux `MADV_DONTNEED`;
  Windows releases and recommits; Darwin `MADV_FREE_REUSABLE` may keep the
  bytes). The live objects in X are zeroed from page 1 on. Page 0 is never
  released (`chunk_layout.cr`).
- **Revive**: `bitmap_revive_dormant` takes the first dormant chunk of the
  class, doesn't ask about CURSOR, and zeroes `occ` and `mark`. Every block
  in X, live ones included, can then be handed out again. A revive while A
  still holds X puts two cursors on one chunk.
- The incremental barrier also leaves dormant chunks unprotected
  (`barrier.cr`).

The lazy sweep is safe because the after-world sweep takes the chunk's
class lock (`fl_locked`), which a taker holds from its check through its
take. A widened window with the lazy sweep stays clean (below).

### Proof: widen the window

`instr-widen-8b9e7eab.patch` counts takes of dormant chunks and, with
`WIDEN_NS`, spins that many nanoseconds between `bitmap_pool_candidate?` and
`set_cursor`. `instr-widen-d2594ff8.patch` does the same on the tree before
the claim (`d2594ff8`, identical to v0.37.0 in `bitmap_alloc.cr` and
`collect_sweep.cr`). The harness there reads `cursor_claims_released` as a
stub returning 0.

| tree | window | arm | runs | failed | dormant takes |
|---|---|---|---|---|---|
| `8b9e7eab` | 50 µs | in-stop | 20 | **20** | 240 (7–19 a run) |
| `d2594ff8` (0.37.0) | 50 µs | in-stop | 20 | **20** | 231 |
| `8b9e7eab` | 50 µs | lazy | 10 | 0 | 0 |
| `8b9e7eab` + fix | 50 µs | in-stop | 40 | 0 | 0 |

Every widened failure has the same sign of drift (live −900 to −10 513).
Nearly all also break stamps (`red/wide-*.log`). The harness keeps 40
error lines a run, and a block checked again counts again. Of those lines:

| runs | zeroed | zeroed tail | another owner's stamp |
|---|---|---|---|
| `8b9e7eab`, 20 | 519 | 49 | 156 |
| `d2594ff8`, 20 | 349 | 32 | 176 |

"Zeroed" reads `0x0 0x0`: the flush released the block's pages under it.
"Zeroed tail" keeps its first words and lost the page its last word is on.
"Another owner's stamp" is a block handed out twice: a revive zeroed the
chunk's `occ` under the live block and a second worker was handed it.
Some runs also refuse legitimate frees. [INFERENCE] These are frees into
a chunk a revive has zeroed, where the block reads as not allocated. Some
runs end with a dormant chunk still holding blocks: for example class 4
with 1632 of 1632 occupied, the overnight signature, or class 29 with 8.

## The fix

In the stop, while a frozen thread holds `@chunk_list_lock`, the sweep now
makes no chunk dormant, just as it already relinks nothing and unmaps
nothing then (`Heap#sweep`, after the header-chunk check of `can_dormant`).
Such an empty chunk stays mapped, awake and in the pool until a later major
finds the lock free. `stop_sweep_dormant_declined` counts these chunks.
`stop_sweep_dormant_lock = false` (research only) restores the code before
and is the control arm of the regression test. After-world sweeps are
unchanged, and so is a stop whose sweep took the lock itself. Such a stop
is rare (`stop_sweep_relinks_declined` counts it), and the cost is the
RSS of that stop's empty chunks until the next major.

`bench/claim_stress.cr` now also fails a run that ends with a dormant chunk
holding blocks or a cursor, and names that chunk's class. A revive usually
zeroes such a chunk before the end, so drift stays the main witness. With
the window widened and no fix, 2 of 5 runs also failed the new check
(class 29, 8 blocks; class 4, 799 blocks).

## Regression test

`process_spec/regression/80_stop_sweep_frozen_pool_taker_spec.cr` forces
the interleaving. `Heap#pool_take_hook` (research only, under the class and
list locks) parks a thread between its check of chunk X and its take until
a stop has come and gone. The main thread collects with `lazy_sweep =
false`. X is a 24 576-byte class chunk that the main thread filled with
three blocks, kept across a collection that retired its cursor, then freed,
so it's empty whatever the conservative scan sees. Each arm runs in its
own process.

- Fixed arm: the stop declined the relink, and the taker's block is in X.
  X is not dormant, occupancy is 1, live and free drift are 0, and a
  declined dormancy was counted. After another collection the block's
  first and last words still hold their stamps and drift is still 0.
- Control arm (`stop_sweep_dormant_lock = false`): X is dormant and
  CURSOR, and live drift is −1.

Red before the fix (the default flipped to the old code): the fixed arm
fails with `dormant?(chunk)` true. With that assertion and the counter
assertion removed, three runs of the child each read live drift −1, free
drift +24 576, and the live block's last word `0x0` after the next
collection. That word is in page 6 of X, released by the flush; its first
word is in page 0 and survives. Green after: 20 of 20 runs, also with
`GCRY_DEBUG_INVARIANTS=1`, and under `-Dgcry_block_headers
GCRY_BITMAP_ALLOC=0`, where the children skip.

## Rate after

| tree | build | arm | runs | failed |
|---|---|---|---|---|
| `01ef5a8d` (fix and harness check) | release | in-stop, seeds 1001–1200 | 200 | 0 |
| `01ef5a8d` | release | lazy, seeds 1001–1100 | 100 | 0 |
| fix, window widened to 50 µs | release | in-stop, seeds 1001–1040 | 40 | 0 (0 dormant takes) |

Seeds 1038 and 1073 are in the in-stop range. At the natural rate, 0 of
200 against 2 of 212 before is suggestive, not proof: if the before rate
holds, 200 clean runs happen by chance about 15% of the time. The widened
window (20 of 20 against 0 of 40) and regression 80 are the evidence that
the window is closed.

`crystal spec -Dgc_none spec/all_specs.cr`: 295 examples, 0 failures.
`crystal spec -Dgc_none process_spec`: 216 examples, 0 failures.
`crystal tool format --check` and `make lint` (ameba, 233 files) are
clean.

## Before the claim

The bug predates the claim. 0.37.0 has it. `bitmap_take_pool_chunk`, the
dormant branch of `Heap#sweep` and `bitmap_revive_dormant` are the same in
v0.37.0, in `d2594ff8` (the tree the claim was made on; no diff to
`bitmap_alloc.cr` or `collect_sweep.cr` since v0.37.0) and in
`8b9e7eab`. The claim didn't touch them. The harness builds on `d2594ff8`
once `cursor_claims_released` is a stub
(`instr-widen-d2594ff8.patch`, which counts dormant takes but not slot
stores):

| tree | window | arm | runs | failed | dormant takes |
|---|---|---|---|---|---|
| `d2594ff8` | none (`WIDEN_NS=0`) | in-stop, seeds 1001–1100 | 100 | **2** (1060, 1087) | 1 in each failing run, 0 in the 98 others |
| `d2594ff8` | 50 µs | in-stop, seeds 1001–1020 | 20 | **20** | 231 |

Both natural failures zeroed live stamped blocks (`red/instr-d2594ff8-*`).
Seed 1060 drifted live −2696 and +129 408 bytes, and 11 blocks of 32 bytes
(atomic, class 2) read zero. Seed 1087 drifted live −8 and +49 152 bytes
(8 × 6144, class 29), and its 6000-byte blocks read zero, whole or from
the second page on.

## Impact

**Memory safety: affected, not only counters.** Live objects in the
mis-dormant chunk are zeroed by the flush after every later collection
(seed 1073's 9 zeroed blocks at the natural rate, and 11 and 8 in the two
natural failures on `d2594ff8`). A revive hands their blocks
out again while they are live: another owner's stamp in a block, 156 and
176 times in the widened runs. The mark doesn't test DORMANT (no reader in
`collect*.cr`), so what those objects point to stays traced; the objects
themselves are what is destroyed. The class-4 drift of the overnight
failure is the same event in a chunk of `select` garbage, where nothing
checks the bytes.

Affected configurations, 0.37.0 and earlier included: a process heap with
more than one mutator thread. The sweep must run inside the stop
(`GCRY_DISABLE_LAZY_SWEEP=1`, `GCRY_PAGE_DONTNEED=1`, the finishing slice
of `GCRY_INCREMENTAL=1`, or `lazy_sweep = false` from code) and must make
empties dormant in that stop: a multi-mutator `GC.collect`, the idle or
out-of-memory collection (`parallel_release_on_collect`), or a dormant
budget (`GCRY_EMPTY_CHUNK_RETAIN`, `GCRY_PARALLEL_DORMANT`, Darwin's
default 512 KiB). On top of that, the stop must freeze another thread
between `bitmap_pool_candidate?` and `set_cursor`. The default
configuration, lazy sweep on, isn't affected.

**What the counters drive.** `live_objects` and `free_bytes` are reporting
counters: `GC.stats`, `GC_get_heap_usage_safe`, `/gc-stats`, the invariant
walks. Nothing in collection triggering or pacing reads them. The
threshold follows `live_bytes_after_sweep`, from the sweep's own walk, and
triggering follows `bytes_since_gc`; neither is touched. Pacing sees one
chunk's live bytes less per event, because the sweep counts a dormant
chunk fully free. RSS: the mis-dormant chunk's pages are released and
faulted back each cycle while it's in use, and its garbage is never
reclaimed until a revive zeroes it. The fix keeps a declined stop's empty
chunks resident until the next major.

## Files

- `red/overnight-8b9e7eab-stop-seed1038.txt`: the reported failure.
- `red/base-8b9e7eab-stop-seed1073.log`: the natural failure here, with
  zeroed stamps.
- `red/instr-d2594ff8-stop-seed1060.log`, `red/instr-d2594ff8-stop-seed1087.log`:
  the natural failures on the tree before the claim.
- `red/wide-8b9e7eab-stop-seed1001.log`, `red/wide-d2594ff8-stop-seed1006.log`:
  widened, on both trees.
- `stress/*.instr`: one line per run (seed, exit, counters, drift).
  `stress/*.summary`: one line per failing run, then the total.
- `instr-widen-8b9e7eab.patch`, `instr-widen-d2594ff8.patch`: the
  instrumentation. Build with `WIDEN_NS=<ns> crystal build -Dgc_none
  --release bench/claim_stress.cr`.
