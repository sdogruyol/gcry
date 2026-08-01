# EC4 RSS A/B — Parallel empty-chunk reclaim

Tip after thr-gap + 100× green soak. `wrk -c100 -d20` `/json`, med-of-3.

## Results

| Config | thr med | RSS med | soft | Notes |
|--------|--------:|--------:|-----:|-------|
| **gate / default** (no Parallel reclaim) | **~42–45k** | **~141–240kB** | 0/3 | thr preserved |
| dormant-all (`GCRY_PARALLEL_DORMANT=1`) | **~32–35k** | **~46–57MB** | 0/3 | RSS ~3× better, thr ~25% down |
| full munmap (`GCRY_PARALLEL_RELEASE=1`) | ~36k | ~63MB | 0/2 | trial 3 **hung** (killed) |

Boehm EC4 RSS was ~17MB on prior cuts — still a large gap even with dormant.

## Verdict

Do **not** default Parallel to dormant or munmap: thr regression / hang risk.
Keep Parallel empty reclaim **off**; EC1 unchanged (dormant+munmap).

Opt-in:
- `GCRY_PARALLEL_DORMANT=1` — DONTNEED all empty chunks, keep VA/index
- `GCRY_PARALLEL_RELEASE=1` — also munmap excess (experimental; can hang)

Next Parallel RSS lever needs something that does not re-fault / expand STW
work the way dormant-all does (or accept thr trade for RSS-sensitive apps).
