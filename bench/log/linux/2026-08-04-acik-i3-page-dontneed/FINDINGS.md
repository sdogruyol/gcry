# Mostly-empty reclaim via `GCRY_PAGE_DONTNEED=1` (i3 acik) — REJECT default

**Date:** 2026-08-04 · Host: WSL2 **i3-12100F** · tip+EC `base`, retain=0  
**Knob:** `GCRY_PAGE_DONTNEED=1` (Linux HOLED free-page madvise; existing opt-in)  
**Control:** `…/2026-08-04-acik-i3-retain0-med3/` — **~96%** thr @ **~1.63×** RSS  
**Harness:** `GCRY_FLAGS=` passthrough on `acik_stackmap_ab.sh` (scrub-safe)

## Motivation

Residual anatomy (`…/acik-i3-residual/`): ~300 chunks `<25%` full; live drains but
`small_free` stays mapped. HOLED page release is the existing lever aimed at
that freelist RSS.

## Smoke (15s × 1)

| variant | thr % | RSS × |
|---------|------:|------:|
| boehm | 100% | 1.00× |
| base + PAGE_DONTNEED | **86%** | **0.63×** |

Looks promising — thr soft, RSS under Boehm.

## Med-of-3 (30s)

| trial | thr rps | % Boehm | RSS KiB | × | heap MiB | fill_lt25 |
|------:|--------:|--------:|--------:|--:|---------:|----------:|
| 1 | 103 | ~77% | **379372** | **~6.8×** | **395** | **2839** |
| 2 | 112 | ~84% | 38252 | 0.68× | 50 | 120 |
| 3 | 108 | ~80% | 32964 | 0.59× | 42 | 83 |
| **med** | **108** | **~80.5%** | **38252** | **0.68×** | — | — |

t1 is the known HOLED failure mode: freelist rebuild / abandoned free pages →
**chunk churn** (fill_lt25 explodes, heap ~400 MiB). Median RSS looks good only
because 2/3 trials stayed small — **not shippable**.

## vs control

| | thr | RSS × | Notes |
|--|----:|------:|-------|
| retain=0 default | **~96%** | **~1.63×** | stable |
| + PAGE_DONTNEED | **~80%** | 0.6× or **~7×** | thr↓ ~15 pp; RSS lottery |

## Verdict

**REJECT as process default** — confirms prior ACIKTURKIYE note (thr + RSS both
can worsen). Keep `GCRY_PAGE_DONTNEED=1` research opt-in only.

Closing the stable ~1.6× freelist residual needs a **different** mostly-empty
strategy than HOLED page release (e.g. bounded high-free-ratio chunk DONTNEED
without freelist rebuild — not implemented; measure before inventing).

Product path unchanged: retain=0, no PAGE_DONTNEED.
