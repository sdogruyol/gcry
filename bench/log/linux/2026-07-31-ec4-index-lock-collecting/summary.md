# EC4: `chunk_containing` lock only under `@world_stopped`

## Bug

`chunk_containing` skipped `@index_lock` when `@collecting || @world_stopped`.
Collect sets `@collecting` through post-STW flush **after** `start_world`, so
Parallel mutators race `index_insert` vs unlocked binary search / last-chunk
cache → `owns_user_pointer?` false → soft `pointer is not a gcry allocation`.

## Fix

Skip lock only when `@world_stopped`.

## Soak 60× (`wrk -c100 -d8` `/json`, TLAB off, empty-chunk gate)

| | |
|--|--:|
| process OK | **60/60** |
| soft realloc | **0/60** |
| hard SEGV | **0** |
| thr med | **~43.7k** |

Baseline before this fix (gate only): soft **2/60** (`2026-07-31-ec4-residual-soft`).
