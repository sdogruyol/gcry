# EC4 Parallel: no empty-chunk release under multi-mutator

Gate: `release_empty_chunks_this_collect?` → false when `multi_mutator_threads?`
(EC1 still releases). TLAB off, default LAG 512 KiB, no `GCRY_KEEP_CHUNKS`.

## Soak 40× (`wrk -c 100 -d 8` `/json`)

| | |
|--|--:|
| process OK | **40/40** |
| soft `not a gcry allocation` | **3/40** |
| hard SEGV | **0** |
| thr med (OK) | **~43.2k** (min ~35k, max ~47k) |

Compare prior A/B soft/40: default release **22**, KEEP_CHUNKS **5**, LAG 2MiB **24**.

## Thr smoke d=20

| | |
|--|--:|
| req/s | **~43.2k** |
| `released_chunk_bytes` | **0** |
| `fully_free_chunk_bytes` | ~55 MiB |

RSS rises vs release-on (expected). No `PERF.md` fold-in.
