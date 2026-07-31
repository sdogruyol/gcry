# EC4 thr-gap baseline (pre skip/threshold)

`wrk -c 100 -d 20` `/json`, TLAB off, med-of-3.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Medians

| | req/s |
|--|------:|
| med | **~46.1k** |

Pre–trylock-skip / 64 MiB threshold cut. See `raw.tsv`.
