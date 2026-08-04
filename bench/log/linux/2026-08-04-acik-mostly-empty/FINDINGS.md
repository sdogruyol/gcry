# Mostly-empty reclaim (HOLED-less) — code + 9950X measure

**Date:** 2026-08-04 · Host: WSL2 **Ryzen 9 9950X** · tip+EC `base` · retain=0  
**Parent residual:** [acik-i3-residual](../2026-08-04-acik-i3-residual/FINDINGS.md) ·  
HOLED reject: [acik-i3-page-dontneed](../2026-08-04-acik-i3-page-dontneed/FINDINGS.md)  
**Knob:** `GCRY_MOSTLY_EMPTY=1` (opt-in; not process default)  
**Modes:** default `MADV_FREE` · `GCRY_MOSTLY_EMPTY_MODE=dontneed` (unlink free-only runs + DONTNEED, no class rebuild)

## Design (vs HOLED / PAGE_DONTNEED)

| | HOLED (`PAGE_DONTNEED`) | mostly-empty free | mostly-empty dontneed |
|--|-------------------------|-------------------|------------------------|
| Freelist rebuild | yes (skip holes) | **no** | **no** (per-run unlink only) |
| Advice | MADV_DONTNEED | **MADV_FREE** | MADV_DONTNEED |
| Flag | `HOLED` | `SPARSE` | `SPARSE` |
| Churn risk | high (abandoned free → new mmap) | low (freelist intact) | high (capacity abandoned) |

Init bug fixed while landing: `ENV[]` during `GC.init` → SEGV; mode parse uses `LibC.getenv` only.

## Same-host results (acik `/api/v1/`, wrk -c100)

| Cut | thr % | RSS × | Notes |
|-----|------:|------:|-------|
| control med3 (`…-control-med3/`) | **~100%** | **1.56×** | tip retain=0 |
| free smoke 15s | 97% | 1.65× | `mostly_empty_bytes` ~3 MiB advised |
| free med3 (`…-free-med3/`) | **98%** | **1.81×** | stable; **no RSS win** (MADV_FREE) |
| dontneed smoke 15s | 97% | **0.85×** | looks good once |
| dontneed med3 (`…-dontneed-med3/`) | **~62%** | 0.74×† | **2/3 COLLECT_HANG**; thr cliff |

† RSS med only from the one non-hang trial; not shippable.

### Anatomy

- Control: `small_free` ~35–44 MiB, `fill_lt25` ~270–340 — freelist residual unchanged.
- Free mode: advises ~2.5–4.5 MiB / ~70 chunks/major; RSS stays mapped (kernel defers reclaim).
- Dontneed t1: heap ~40 MiB / RSS under Boehm, but `small_free_bytes` counter goes absurd (~hundreds of MiB) — freelist/accounting damage; later trials hang on `/gc-collect`.

## Verdict

| Mode | Product default? | Why |
|------|------------------|-----|
| `MOSTLY_EMPTY` + MADV_FREE | **No** | Safe-ish thr, **does not move RSS gate** |
| `MODE=dontneed` | **REJECT** | Same failure class as HOLED: RSS lottery + **COLLECT_HANG** / thr↓ |
| Keep code | research opt-in | Wire stays for further mostly-empty ideas (evacuate / bounded budgets) |

Closing stable ~1.4–1.6× freelist residual still needs something other than
page-advice-on-sparse-chunks (compaction / tighter growth / accept floor).

**Do not** ship as default. Product path unchanged: retain=0, no PAGE_DONTNEED,
no mostly-empty.
