# EC4 GCRY_CHUNK_BYTES=256 KiB A/B (no ship)

Tip: lazy-sweep **78.8%**. Env-only (Darwin process default already 256 KiB).

## Soft soak ×40

| OK | soft | thr med |
|---:|-----:|--------:|
| **40/40** | **0** | **~70.9k** |

Chunks ~374 (was ~745).

## Quiet thr

Session `2026-08-01-132744/`: `/json` **78.7%** @ ~73k — flat vs 78.8%
hold; not enough for stretch ~80% or a Parallel Linux default change.
