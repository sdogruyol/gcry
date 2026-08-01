# EC4 long soak 100× (post thr-gap fixes)

Tip `af1a74a` — empty-chunk Parallel gate + index_lock + trylock-skip + 64 MiB
Parallel threshold. TLAB off. `wrk -c 100 -d 8` `/json`, fresh process/trial.

Counts **soft** (`pointer is not a gcry allocation` / `not a live gcry`) and
**hard** (SEGV), not only process-alive.

| | |
|--|--:|
| process OK | **100/100** |
| soft realloc | **0/100** |
| hard SEGV | **0** |
| boot fail | 0 |
| OK thr med | **~46.2k** (min ~32k, max ~53k) |

Prior long soak (`2026-07-31-ec4-soak-100/`, LAG+mutex+coalesce only): **96/100**
hard-alive, 4× SEGV/MARK_MISS (soft undercounted).

**Verdict:** short HTTP soak is green under current Parallel defaults. EC>1
still experimental (thr ~68% Boehm, RSS high). No `PERF.md` fold-in.
