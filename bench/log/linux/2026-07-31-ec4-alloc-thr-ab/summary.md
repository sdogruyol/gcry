# EC4 alloc-path contention A/B

Tip after thr-gap + RSS opt-in. TLAB off unless noted.
`wrk -c 100 -d 20` `/json`, median-of-3, fresh process/trial.
Session: this dir. Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Levers tried

| Lever | Result |
|-------|--------|
| `GCRY_TLAB=1` @ EC4 | thr med **~24k** vs off **~42k** (~57%); soft 0 — **not a thr win** |
| `@alloc_lock` → `pthread_mutex` | thr **~12k**, `collections=0`, heap ~1.7 GiB — **STW deadlock** (suspend-while-holding). Reverted. |
| Fold `note_alloc_bytes` into freelist `@alloc_lock` (SpinLock) | TLAB-off med **~53k** (host; matches thr-gap abs). TLAB-on still **~26k** after folding the second lock. |

## Medians (req/s, d=20)

| Config | med | soft | notes |
|--------|----:|-----:|-------|
| tlab_off (pre-fold) | ~42k | 0 | `raw.tsv` |
| tlab_on | ~24k | 0 | hit rate high; still serialises on `@alloc_lock` + `find_block` |
| mutex (rejected) | ~12k | 0 | cols=0 — see `../2026-07-31-ec4-alloc-mutex/` |
| fold_off (SpinLock) | ~53k | 0 | `raw-fold.tsv` / `raw-spinlock.tsv` |
| fold_on | ~26k | 0 | one `@alloc_lock` per hit; still loses |

## Decision

- Keep **`Crystal::SpinLock`** for `@alloc_lock` (comment in heap/tlab).
- Keep **counter fold** (TLAB-off one lock; TLAB one lock inside `tlab_alloc_small`).
- **`GCRY_TLAB` stays opt-in** — Parallel thr still worse than off.
- Do **not** fold into `PERF.md`. Next levers: atomic alloc counters (drop `@alloc_lock` on TLAB hit), or per-size-class SpinLocks that never sleep under STW.
