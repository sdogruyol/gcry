# Phase 3's sweep and allocation claims, measured on the axes they were restated on

**Date:** 2026-09-23 · host: Linux 7.0.0-31-generic x86_64 (QEMU), Crystal 1.21.0
`bench/micro/gc_phases.cr` built `-Dgcry_block_headers` · raw rows beside this file

Phase 3 replaced the freelist with `occ` bitmaps, a streaming `occ &= mark`
sweep and per-thread cursor allocation. When the phase gates were restated
on the axis each phase moves, Phase 3's became `phase_sweep` **and**
`ns_per_alloc` — and `tasks/todo.md` has said since that both claims were
unmeasured. The end-to-end case was made on Kemal (freelist 74.9% of Boehm
at 1.87x peak RSS, bitmap 105.3% at 1.30x, `2026-09-06-bitmap-default-ab`);
the mechanism never had its own numbers.

## Set-up, and the confound removed

The freelist exists only on the header layout, so both arms are that
build, `GCRY_BITMAP_ALLOC=0` vs `1`. The bitmap allocator also brings the
adaptive threshold, which on a first trial gave 90 collections against
284 and made every per-run number a comparison of two policies. Pinned
with `GCRY_THRESHOLD=33554432` in both arms, so only the mechanism
differs. Workload: `--survival=0.1 --fanout=0` — 90% garbage, which is
what a sweep is for. n=10 per arm, interleaved with alternating order.

| | freelist | bitmap | Δ | t |
|---|---|---|---|---|
| `phase_sweep_us` | 7 236 ± 563 | 41 ± 15 | **−99.4%** | −40.4 |
| `ns_per_alloc` (end to end) | 73.2 ± 2.4 | 39.1 ± 2.3 | **−46.6%** | −32.9 |
| `pause_per_gc_us` | 15 577 ± 858 | 14 582 ± 942 | −6.4% | −2.47 |
| `rss_kb` | 65 739 | 64 890 | −1.3% | −46.5 |
| `collections` in 3 s | 78 | 147 | +88% | |

## What that says

- **Sweep**: ~180x. The header walk is O(blocks) reading every header; the
  bitmap sweep is O(blocks/64) over two words per 64 blocks, vectorised,
  touching no payload. This is the claim in the sweep's own comment, now
  with a number under it.
- **Allocation**: the per-allocation cost halves. The cursor hands out a
  block from a word it already holds; the freelist follows a link into the
  block it is about to return, which is a miss on a cold free list.
- Pause per collection barely moves, and should not: both arms sweep after
  the world restarts (`sweep_after_world?`), so the sweep is off the pause
  in either case — its cost lands on the mutator, which is where
  `ns_per_alloc` sees it.
- The collection count nearly doubles *because* allocation is cheaper: the
  same 3 s allocates twice as much, at a pinned threshold. Per-collection
  and per-allocation numbers are the fair ones; per-run totals are not.
