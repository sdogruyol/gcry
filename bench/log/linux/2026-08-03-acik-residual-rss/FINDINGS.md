# Residual ~1.81× RSS after finalizer fix

**Date:** 2026-08-03 · **Host:** WSL2 9950X · tip+EC `base` (no stackmaps)

Gate med3 (`…/acik-finalizer-gate-med3/`): **1.81×** Boehm RSS, thr **91.5%**.
This session asks *what* the leftover is.

## Anatomy (med3 `base` gcstats, post dual-collect)

| trial | RSS MiB | heap | free | live_sc | fully_free | large_mapped | large_cache_retain | empty_retain |
|------:|--------:|-----:|-----:|--------:|-----------:|-------------:|-------------------:|-------------:|
| 1 | 98.8 | 108 | 103 | 5.3 | 53.9 | 32.6 | 32 | 16 |
| 2 | 59.3 | 82 | 78 | 11.6 | 28.5 | 27.5 | 32 | 16 |
| 3 | 98.7 | 108 | 75 | 16.2 | 34.5 | 29.3 | 32 | 16 |

Live size-class payload is **~5–16 MiB**. Process RSS is dominated by
**mapped-but-free** heap (freelist + empty/dormant chunks) and a grown
**large-object cache** (adaptive retain **32 MiB**; Linux default floor 4 MiB).
`finalizer_entries` ~150 — not the old sticky leak.

Boehm `/gc-stats` is empty under this app (not gcry JSON); Boehm RSS med **~55 MiB**.

## Knob A/B (single trial, wrk 20s + dual collect)

| config | RSS MiB | thr | × Boehm (48.2 MiB) |
|--------|--------:|----:|-------------------:|
| control (defaults) | 65.6 | 123 | 1.36× |
| `GCRY_EMPTY_CHUNK_RETAIN=0` | 70.9 | 112 | 1.47× |
| `GCRY_LARGE_CACHE=0` | 76.8 | 130 | 1.59× |
| **both =0** | **42.0** | **136** | **0.87×** |
| boehm | 48.2 | 134 | 1.00× |

Either knob alone does **not** close the gap (large cache still 32 MiB when
only empty-retain is zeroed; zeroing large cache alone leaves empty/dormant
mapped). Together, RSS drops **below Boehm** in this one smoke — thr held.

## Verdict

| Layer | Status |
|-------|--------|
| Dead finalizable retention | **fixed** (`3a0bffe`) |
| Residual vs Boehm | Mostly **allocator caches / mapped free**, not live graph |
| Product default change | **not yet** — need med3 thr+RSS before shipping retain=0 |

Next if chasing ≤1.5× as default: med3 `GCRY_LARGE_CACHE=0` +
`GCRY_EMPTY_CHUNK_RETAIN=0` (or a smaller adaptive cap), watch thr/VMA churn.
