# Tight small-heap growth — acik freelist residual lever

**Date:** 2026-08-04 · Host: WSL2 **Ryzen 9 9950X** · tip+EC `base` · retain=0  
**Knob:** `GCRY_TIGHT_GROW=1` (opt-in; not process default yet)  
**Parent:** [acik-i3-residual](../2026-08-04-acik-i3-residual/FINDINGS.md) · page-advice REJECTS  
**Hub session (cite):** `…/2026-08-04-acik-tight-grow-v2-med3/`

## Design

Non-moving, no HOLED / DONTNEED:

1. **Prefer newest chunk freelist** — alloc/free sticky to the latest
   `map_chunk` for each size class so older chunks can go fully empty → munmap.
2. **Sparse GC-before-grow** — before mapping when freelist empty, major collect
   only if `small_free/small_mapped ≥ tight_grow_gc_pct` (default 35%) and
   `bytes_since_gc` is material. Avoids the v1 STW storm (~1k majors/30s).

Escape: `GCRY_DISABLE_TIGHT_GROW=1`, `GCRY_DISABLE_TIGHT_GROW_GC=1`.

## Results (acik `/api/v1/`, wrk -c100 -d30, med-of-3)

| Cut | thr % | RSS × | Notes |
|-----|------:|------:|-------|
| control (`…-mostly-empty-control-med3/`) | **~100%** | **1.56×** | tip retain=0 |
| v1 full GC-before-grow | **~84%** | **0.85×** | thr cliff; ~1k collects |
| prefer-only (no GC) | ~118% | **1.73×** | no RSS win |
| **v2 sparse GC** (`…-v2-med3/`) | **103%** | **0.92×** | **ship candidate (opt-in)** |

v2 trial RSS KiB: 38872 / 39916 / 73352 — median **0.92×**. t3 is the fat
outlier (heap 77 MiB); t1/t2 release ~18–21 MiB empty chunks.

### Kemal `/json` (same host, `GCRY_TIGHT_GROW=1`)

| | % Boehm | RSS × |
|--|--------:|------:|
| tip default (office profil) | ~80% | 0.79× |
| **+ TIGHT_GROW** (`…/2026-08-04-085740/`) | **77.6%** | **0.78×** |

~2–3 pp thr soft vs tip; RSS already under Boehm. Soft ≥90% still MISS.

## Verdict

| Question | Answer |
|----------|--------|
| Closes acik ~1.6× freelist floor? | **Yes** — median **~0.92×** @ **~103%** thr |
| Linux process default? | **Not yet** — Kemal thr soft; keep opt-in; reconsider after more hosts |
| vs PAGE_DONTNEED / mostly-empty | **Wins** — stable thr+RSS, no COLLECT_HANG |

**Product:** `GCRY_TIGHT_GROW=1` for fat HTTP. Version stays **v0.17.0**.
Do not tag v0.18 for this alone.
