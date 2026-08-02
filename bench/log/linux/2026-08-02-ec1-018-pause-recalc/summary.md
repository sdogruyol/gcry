# Skip post-rebuild `recalc_free_bytes` — ship

## Lever

After empty/HOLED freelist rebuild, drop the full-heap `recalc_free_bytes`
walk. Keep `@free_bytes` coherent via existing `reclaim_small` /
`freelist_reserve` / large-cache updates, plus `free_bytes_sub(free_payload)`
on munmap empties (FREE payload counted in the defer discover pass).

## Under-load TRACE (`/json` d=30) vs prior EC1 lazy

| | lazy + recalc (`pause-lazy/`) | skip recalc (this) |
|--|------------------------------:|-------------------:|
| pause med | 0.586 ms | **0.576 ms** |
| sweep med | 3.466 ms | **2.627 ms (−24%)** |
| flush med | 1.500 ms | 1.539 ms |
| wrk | 34200 | 34504 |

## Soft

`make soak-smoke` **PASS**.

## Verdict

**Ship.** Pause already ~0.6 ms (sweep outside STW); this cuts post-STW
sweep wall ~0.8 ms. Not a thr headline.
