# EC4 atomic alloc counters (+ suppress fix)

`wrk -c 100 -d 20` `/json`, median-of-3, fresh process/trial.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Changes

1. **Atomic** `@bytes_since_gc` / `@total_bytes` / `@live_objects` /
   `@free_bytes` / `@nursery_alloc_bytes` / `@tlab_hits` — TLAB hit path no
   longer takes `@alloc_lock` for accounting.
2. **Atomic `@suppress_collect`** — Parallel `realloc` races on plain `Int`
   left suppress stuck high (≈4607) → `maybe_collect` skipped forever
   (`collections=0`, thr ~13k). Exposed when alloc critical sections got
   shorter; was latent under SpinLock-held counter updates.

## Medians (req/s)

| Config | med | cols | notes |
|--------|----:|-----:|-------|
| TLAB off | **~51k** | ~90–100 | ≈ prior fold baseline (~53k) |
| `GCRY_TLAB=1` | **~26k** (~52%) | ~45–48 | soft 0; still not a thr win |

Broken intermediate (pre-suppress fix): off/on ~13k/11k, cols=0.

## Decision

Ship Atomic counters + Atomic suppress. Keep `GCRY_TLAB` **opt-in**. Remaining
TLAB tax: `find_block` + per-slot lock on every hit. No `PERF.md` fold-in.
