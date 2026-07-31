# EC4 post-STW coalesce-only (noise / interim)

`wrk -c 100 -d 20` `/json`, TLAB off.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Medians

| | req/s |
|--|------:|
| med | **~39.0k** |

Interim before trylock-or-skip. See `raw.tsv`.
