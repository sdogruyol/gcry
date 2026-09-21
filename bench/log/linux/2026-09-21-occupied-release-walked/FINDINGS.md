# `make occupied-release` walks its window instead of waiting for it

**Date:** 2026-09-21 · host: Linux 7.0.0-31-generic x86_64 · Crystal 1.21.0
Tree `788245a` · `python3 bench/gate_arm_census.py`

The last per-gate note named two CI gaps. This is the one whose harness
existed and could not fail: `bench/occupied_release.cr` tried to reach
the window that released a chunk with a live block in it (CI
`34787711949`, 2026-09-14) with thread churn and a held flush, reached
it 0 of 48 here, reported INCONCLUSIVE and exited 1 — so the recipe ran
both arms under `-` and the refusal it exists to protect had no gate.

## The window has a single-thread shape

Read from the code, then confirmed by construction:

1. `bitmap_settle_cursor_sets` retires every cursor inside the stop and
   bumps the class's pool version, so after a collection the next take
   rebuilds the pool from `@chunks`.
2. With the lazy sweep (the default, `sweep_after_world?`), that list is
   still intact after `start_world` — the sweep that unlinks empties
   has not run. A pool built then holds every idle chunk.
3. The sweep frees nothing in a chunk that was already empty last cycle
   (`freed == 0` → no `bitmap_capacity_changed`), so it queues those
   chunks without invalidating that pool. They leave `@chunks` and stay
   in `@chunk_index`.
4. A cursor exhausted before the flush pops the next pooled address;
   `bitmap_indexed_chunk` still answers, `bitmap_pool_candidate?`
   accepts an all-free chunk, and a block is handed out of a chunk queued
   for unmapping.

The process-GC sighting is the same sequence with a thread born during
the stop as the mutator, which is why it needed the single-mutator latch
and why it arrived once in twenty-four children.

## What changed

- `Heap#post_stw_hook : Proc(Symbol, Nil)?` — research only, library
  heaps — called on the collector's thread at `:after_start_world` and
  `:before_flush`. It replaces `GCRY_EMPTY_FLUSH_DELAY_MS` and
  `Heap#empty_flush_delay_ms`, which had no remaining user.
- `bench/occupied_release.cr` is a library-heap harness: six chunks of
  4 KiB garbage, one major (all seven chunks on grace), then a second
  major whose hook takes one block after `start_world` and exhausts that
  chunk before the flush. Both arms require the window: exactly one
  refusal counted, no `map_chunk` during the window, a block whose chunk
  differs from the first. Shipped then writes the block, collects with it
  rooted and requires it live; `--broken` sets `release_occupied_anyway`
  and requires the block's chunk to be gone from the index, without
  touching it or the heap again.
- Recipe runs both arms without `-`; CI step on x86_64 beside
  `kept-release-report`, and in the Darwin gate list.

## Measured

| arm | considered | refused | mapped in window | verdict |
|---|---|---|---|---|
| shipped | 6 | **1** | 0 | block written, live after a rooted collect — PASS |
| `--broken` | 6 | **1** | 0 | chunk gone from the index — PASS |
| shipped, `return false if @release_occupied_anyway` → `return false` | 6 | 1 | 0 | **FAIL** "refusal was counted and the chunk was released anyway" |
| `--broken`, knob line dropped | 6 | 1 | 0 | **FAIL** "did not release the occupied chunk" |
| either arm, `:before_flush` call dropped | 6 | 0 | 0 | **FAIL** "no block was taken", "window was not hit" |

Deterministic: 1 of 1 on every run tried, ~2 s per `make` including the
two compiles. The refusal line prints once in the shipped arm with
`1 block(s) are allocated in it now`, which is the CI report's `Blocks
still allocated at release: 1` seen from the other side.

## Census

```
harness-driven gates:              100
red direction constructed per run: 70
red direction established by hand: 30
prose claims of a hand break:      19 (nothing re-checks these)
```

**100 / 69 / 31 → 100 / 70 / 30.** `occupied-release` moved: recipe 1
(`--broken`), harness 0.

Still a real gap in CI: `nested-spawn-uaf` (the original repro;
`dead-stack-root` is the gate).
