# EC4 Parallel major threshold A/B

`wrk -c 100 -d 20` `/json`, TLAB off, trylock-skip build.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Medians (req/s)

| Threshold | med |
|-----------|----:|
| 32 MiB | ~46.7k |
| **64 MiB** | **~52.9k** |
| 128 MiB | ~51.1k |

Default: `PROCESS_GC_THRESHOLD_PARALLEL` = 64 MiB. See `raw.tsv`.
