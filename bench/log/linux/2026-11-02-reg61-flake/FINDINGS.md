# Regression 61's positive control, held by a stale word under the collector's entry scrub (2026-11-02)

`process_spec/regression/61_free_link_holder_spec.cr`, second example ("writes
nothing into the block's new owner when a collection reclaims the target"),
failed at `control[0].value.should be_nil` in 1-2 of 11 block-headers
`process_spec` runs on the large-cache-incr commits (`b8bbd85c..87ccf4f4`).
The `WeakRef` target survived three `GC.collect`s. Branch `reg61-040`.

**Verdict:** conservative retention, not a weak-link or sweep defect. A dead
word on the main stack holding the target's *header address* is read by the
collection's own stack scan. The large-cache-incr commits do not run in that
process; they only change the allocation history before 61. The example now
scrubs its dead frames before collecting: 0 of 20 against 4 of 20.

## Rates

Local Linux x86_64 (12-vCPU guest), Crystal 1.21.0, `-Dgc_none
-Dgcry_block_headers`. Each binary is the suite's own files in `crystal spec`'s
glob order, built once and cut after `61_free_link_holder_spec.cr` (48th of
94; 208 examples, ~31 s). Each run under the shared lock, arms interleaved.

| tree | 61 failed |
|---|---:|
| base `07b61d28` | 0 of 15 |
| `87ccf4f4` | 4 of 15 |
| `551acbfc` (origin, 95 reworked) | 4 of 20 |
| `551acbfc` + this change | **0 of 20** |

The instrumented copies of 61 (below) failed at the control 1 of 15, 2 of 15,
1 of 9, 2 of 17 and 2 of 9 runs on `87ccf4f4`.

## What holds the target

Instrumented in steps (`diag-spec.diff`, and `collector-watch.diff` on
`87ccf4f4`'s `src`, neither committed):

1. `GCRY_LIVE_ATTR_WATCH_TID` on `FreedHolderTarget`: in every failing run
   the target was first marked from `RootSource::Stack`, once per collection,
   in all three.
2. The address-space audit (`Heap#audit_address_space`) inside each of the
   three collections found the target's address only in libc memory (the
   link table) and in atomic blocks: no word on any stack equal to it.
3. A watch in `mark_root_candidate`/`mark_explicit_root` with the slot the
   scan was reading (`Roots.hl_slot`): the candidate is **the target minus
   16**, its block header, which the interior rule resolves to the target. In
   every failing run, and in all three collections of each, it was the same
   slot, **584 bytes below `collect_entry_sp`**, inside the window the mutator
   scan used.
4. The target's position: in all 7 instrumented failures it sat at chunk
   offset `0x2e0`, the chunk's **first block** (its header is the chunk's data
   start); in all 43 instrumented passes it sat at `0x310` or `0x340`, the
   second or third.

Making the position deterministic made the failure deterministic: a copy that
allocates targets on the fiber until one is its chunk's first block
(`REG61_FORCE=1`, the 61 file alone) failed 3 of 3, one seed per collection at
that slot.

The words around the slot at the moment of the scan (symbolised against the
binary): `e-528` is the return address of `Pointer(UInt8)#clear` called from
`Heap#clear_stack_body`, the entry scrub's `memset`; `e-608` is a return
address into `Heap#cursor_claim_word`; `e-672`..`e-704` are
`StaticArray#[]` returns (`@block_bytes[index]`).

So, in order:

1. The target is the first block of a fresh chunk, so its header address is
   the chunk's data start, which is also the cursor's word base for word 0.
2. `reuse_block` runs ~60 allocations of the same class on the main fiber.
   Their slow path claims word 0 again (`cursor_claim_word`) and leaves
   `data_start` in a dead frame below the example's.
3. `GC.collect` enters `run_collection`, whose entry scrub (`collect_scrub` →
   `clear_stack_body`) zeroes 16 KiB below `clear_stack_body`'s SP **minus
   `CLEAR_STACK_RED_ZONE + CLEAR_STACK_LEAF_MARGIN` (192 bytes)**: that band
   is where its own `Pointer#clear`/`memset` frame runs. The word sits in it.
4. The collector's later frames do not write that slot, and the mutator scan
   starts at its own SP, deep inside the collector, so it reads the slot. The
   same in every collection: nothing else writes there between them.

## Why 87ccf4f4 and not 07b61d28

In the failing process `nursery=false`, no barrier is armed and nothing runs
incrementally (printed by the first instrumented copy), so
`settle_large_cache` takes the same branch as on base and the incremental
finish never runs. The commits add `95_incremental_large_counters_spec.cr`,
28th in glob order, before 61: six `Process.run`s more in the parent shift the
16-byte atomic class's allocation history so that the target opens a fresh
chunk in some runs. [INFERENCE] On base's history it never did in 15 runs.

## The change

The example calls its existing 64 KiB `freed_holder_scrub` on the main fiber
right before `3.times { GC.collect }`. That zeroes every dead frame its
`GC.free`, `reuse_block` and `finalizer_link_count` calls left, so the
collector's frames, the scrub's band among them, are built over zeros. Every
assertion is unchanged. With the scrub, the forced first-block copy passed 6
of 6 with no seed.

## Not done here

- **The band itself.** The same word can hold any program's block through a
  collection, not only this spec's. A `src` fix would wipe it from
  `run_collection`'s own frame after `collect_scrub` returns (for example
  `Roots.wipe_below_sp(Roots.wipe_limit(sp))`, the allocation path's frameless
  asm wipe). That reaches the band and the scrub's own frames, not the frames
  above `collect_entry_sp`. It runs on every collection, so it needs a
  regression and the keep rule. Not built or measured.
- **Regressions 1 and 21** (reported on later tips): not reproduced or
  measured here. 21's failure ("controls kept 8 > 1", seen once in this
  session on an instrumented `87ccf4f4` prefix run, `tipdiag2pre_9`) had all
  eight independent atomic control blocks live after three collections. One
  stale word holds one block, so [INFERENCE] that is a different class, about
  the blocks not being reclaimed rather than about a root.
- The same session saw regression 95's counters control arm fail once on
  `87ccf4f4` (budget short by one 128 KiB mapping); that went to the 95
  rework in `551acbfc`.

## Checks

On `reg61-040` (`367c3707` + this change), each under the shared lock:

| check | result |
|---|---|
| `crystal tool format --check` (the spec) | clean |
| `make lint` | 249 inspected, 0 failures |
| `crystal spec -Dgc_none process_spec` | 366 examples, 0 failures, 2 pending |
| `… -Dgcry_block_headers process_spec` | 367 examples, 0 failures, 2 pending |
| `GCRY_BITMAP_ALLOC=0 … -Dgcry_block_headers process_spec` | 367 examples, 0 failures, 2 pending |
