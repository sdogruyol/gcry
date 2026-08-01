# EC4 Parallel 256 KiB chunks (no ship)

`wrk -c 100 -d 20` `/json`, interleaved med-of-5.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Medians (req/s)

| Config | med | notes |
|--------|----:|-------|
| `GCRY_CHUNK_BYTES=131072` | ~48k | host noise vs ~55k quiet baseline |
| Parallel default 256 KiB | ~52k | within noise; sweep_ms unchanged |

## Decision

No default change. Darwin stays 256; Linux Parallel stays 128 library default.
