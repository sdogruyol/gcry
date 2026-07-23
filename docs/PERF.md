# Kemal wrk vs Boehm

**gcry req/s ÷ Boehm req/s**, same host. Prefer `/json`. Absolute wrk is host-noisy.

Load: `bench/kemal`, `wrk -c 100 -d 30`, fresh process per path, Crystal release (`-Dgc_none` for gcry).

## History

| Version | `/` | `/json` | notes |
|---------|----:|--------:|-------|
| 0.4.0 | ~86% | ~83% | tagged; STW default |
| main | **~92%** | **~82%** | STW hot-path |
| main + `GCRY_RELEASE_CHUNKS=1` | ~56% | ~49% | opt-in only |

## How to record

Same-day gcry + Boehm on both paths → append a row (and refresh README). Do not invent numbers.

```sh
make bench-kemal-wrk   # gcry; Boehm: same binary without -Dgc_none
```
