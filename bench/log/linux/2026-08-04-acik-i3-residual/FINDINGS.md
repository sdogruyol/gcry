# i3 acik residual ~1.63× — freelist, not live graph

**Date:** 2026-08-04 · Host: WSL2 **i3-12100F** · tip+EC `base`, Linux retain=0  
**Paired cut:** `…/2026-08-04-acik-i3-retain0-med3/` — thr **~96%**, RSS **~1.63×** Boehm  
**Probe:** `acik_live_attr.sh` BIN=base, wrk 30s, dual collect, idle 30s + dual collect  
**Session:** this directory

## Med3 residual (from prior cut)

| | RSS med | heap_size | small_mapped | small_free | live_sc |
|--|--------:|----------:|-------------:|-----------:|--------:|
| i3 tip retain0 | **~81 MiB** (1.63×) | ~85–91 | ~75–77 | **~37–42** | ~16–22 |
| 9950X release0 (1.00× trial band) | ~44 MiB | ~36–67 | ~31–56 | **~8–16** | ~10–15 |
| 9950X defaults verify | ~70–78 MiB (1.4×) | ~73–82 | ~64–73 | ~34–36 | ~16–20 |

Caches already 0 (`empty_chunk_retain` / `large_cache_retain`). Process RSS ≈
`heap_size` — residual is **mapped gcry heap**, not OS cache outside the
allocator. Live payload similar across hosts; **small_free** is the wedge.

## Live-attr (this session)

| Sample | live_attr total | max 32 KiB atomic | live_sc | heap | small_free |
|--------|----------------:|------------------:|--------:|-----:|-----------:|
| post dual-collect | 35.0 MiB | 14.9 MiB | 15.8 | **81.7** | **32.2** |
| idle 30s + dual collect | **11.4 MiB** | **5.3 MiB** | **5.5** | **80.1** | **54.1** |

- ESTAB 0→0 — not live TCP connections.
- Idle drains typed IO / 32 KiB atomics (pool-ish / delayed death) → live falls.
- **heap_size barely moves** (~82→80); freed bytes become **freelist**
  (`small_free` 32→54). Partially occupied chunks never hit empty-chunk munmap
  (retain already 0).

first_mark post: heap ~17 MiB / parked ~6.5 MiB (atomics mostly heap-reached).

## Verdict

| Hypothesis | Result |
|------------|--------|
| Finalizer leak again | **No** — idle drops live; entries not sticky |
| Cache retain residual | **No** — both retains 0 |
| Dense true live vs Boehm | **No** — idle live_sc ~5.5 MiB ≪ RSS gap |
| Mapped freelist / sparse chunks | **Yes** — RSS tracks heap; free grows, mapped stays |

i3 **1.63×** and 9950X verify **~1.4×** are the same shape. The 9950X
release0 **1.00×** median was a low-heap lucky band (trial RSS 37/45/63),
not a different product default.

## Next levers (if chasing ≤1.2×)

1. **Mostly-empty chunk reclaim** — release / DONTNEED high-free-ratio
   non-empty chunks (PAGE_DONTNEED-class; thr risk; prior HOLED default
   rejected).
2. **Tighter small-heap growth** — fewer concurrent size-class chunks under
   HTTP (alloc locality); measure before inventing knobs.
3. **Accept ~1.4–1.6×** as non-moving STW floor on fat HTTP after retain=0 —
   still a large win vs v0.17 i3 **~3.43×** / pre-fix **~8.5×**.

Do **not** re-open exclusivef / stack maps for this residual.
