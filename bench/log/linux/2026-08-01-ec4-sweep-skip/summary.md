# EC4 dirty∪marked clean-chunk sweep skip (REJECT)

Tip: lazy-sweep **78.8%** `/json`. Stretch ~80% residual: O(heap)
`phase_sweep` under Parallel reclaim-off freelist reserve.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Lever (reverted)

Power-of-two **aligned** small mmaps → O(1) `user→chunk`; `NEEDS_SWEEP`
on alloc (no `chunk_containing`) + mark; major reclaim-off skips clean
chunks without freelist lock.

## Soft soak (`wrk -c100 -d8` `/json` ×40)

| OK | soft | hard | OK thr med |
|---:|-----:|-----:|-----------:|
| **40/40** | **0** | **0** | **~66.8k** |

`sweep_clean_chunk_skips` last-collect **~5** / ~745 chunks — freelist
churn dirties nearly every empty chunk between majors. `phase_sweep` still
~16–19 ms.

## Quiet thr (`wrk -c100 -d30` med-of-3)

Session `2026-08-01-131226/`:

| Path | % Boehm | gcry med | Boehm med |
|------|--------:|---------:|----------:|
| `/json` | **72.6%** | 68,738 | 94,728 |

Below lazy-sweep hold **78.8%** (abs also flat/slightly down). Aligned
over-mmap + per-alloc dirty check paid without skipping the hot empties.

## Verdict

**Reject** (code reverted). Same failure class as ALL_FREE / used_count:
skip set is tiny under reclaim-off LIFO freelist churn. Stretch ~80% still
open; bar stays **78.8%**.
