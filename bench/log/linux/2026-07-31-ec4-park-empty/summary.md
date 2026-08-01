# EC4 park-empty + ALL_FREE skip (reject)

`wrk -c 100 -d 20` `/json`, fresh process/trial.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Change (reverted)

- Power-of-two aligned size-class mmap; `ALL_FREE` sweep skip; Parallel park
  empty freelist nodes (no DONTNEED) + revive on refill.

## Medians (req/s)

| Config | med | skips/major | sweep_ms | notes |
|--------|----:|------------:|---------:|-------|
| park+skip | **~39k** | ~2 | ~18 | soft 0; worse than ~55k baseline |

## Decision

**Reject / revert.** Empties are the freelist under reclaim-off; park+skip
cannot stick across a 64 MiB alloc epoch.
