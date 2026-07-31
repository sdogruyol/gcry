# EC4 fiber scrub off (reject)

`wrk -c 100 -d 20` `/json`, TLAB off, `GCRY_DISABLE_SCRUB_FIBERS=1`.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Medians

| | req/s |
|--|------:|
| med | **~37.6k** |

Regresses vs scrub-on ~53k. Keep scrub default-on. See `raw.tsv`.
