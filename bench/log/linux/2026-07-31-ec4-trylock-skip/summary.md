# EC4 post-STW trylock-or-skip

`wrk -c 100 -d 20` `/json`, TLAB off.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Medians

| | req/s | wait_ms |
|--|------:|-------:|
| med | **~43.1k** | ~0.2 |

Drops `post_stw_wait_total` without yield-loop burn. Shipped with 64 MiB
Parallel threshold. See `raw.tsv`.
