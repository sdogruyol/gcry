# EC1 empty_chunk_retain=32 MiB (Phase 1.1)

Session: `bench/log/linux/2026-08-02-122030/` · `GCRY_EMPTY_CHUNK_RETAIN=33554432`

| Path | % Boehm | RSS × |
|------|--------:|------:|
| `/json` | **81.9%** | **0.88×** |
| `/` | **83.6%** | **0.83×** |

vs baseline **87.9%** @ **0.81×**: thr **−6pp**, RSS slightly worse. **Reject** as
process default. A/B chain aborted before retain64 / EC4 baseline.
