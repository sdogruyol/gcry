# EC4 per-size-class freelist SpinLocks

`wrk -c 100 -d 20` `/json`, fresh process/trial.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Change

- Global freelist heads: `@freelist_locks[i]` / `@nursery_freelist_locks[i]`
  (`Crystal::SpinLock`). TLAB-off alloc/free take the class lock only.
- `@alloc_lock` kept for large objects + TLAB table boot + **TLAB refill**
  (putting refill on per-class locks amplified `@index_lock` via parallel
  mmap×`find_block` and crushed TLAB-on thr ~26k→~15k).
- STW sweep still touches freelists unlocked (world stopped).

## Medians (req/s)

| Config | med | notes |
|--------|----:|-------|
| EC4 TLAB-off quiet med-of-5 | **~55k** | `raw-quiet.tsv`; soft 0 |
| EC4 TLAB-off v2 med-of-3 | ~48k | noisier host pass |
| EC4 TLAB-on v2 | **~26k** | recovered with refill on `@alloc_lock` |
| EC1 | ~31k | this host; not a release cut |
| Prior atomic baseline EC4 off | ~51k | `2026-07-31-ec4-atomic-counters` |

## Decision

Ship. Modest Parallel TLAB-off win (~55k vs ~51k). TLAB stays opt-in.
No `PERF.md` fold-in.
