# Kemal wrk vs Boehm

**gcry req/s ÷ Boehm req/s**, same host. Prefer `/json`. Absolute wrk is host-noisy.

Load: `bench/kemal`, `wrk -c 100 -d 30`, fresh process per path, Crystal release (`-Dgc_none` for gcry).

## History

| Version | `/` | `/json` | notes |
|---------|----:|--------:|-------|
| 0.4.0 | ~86% | ~83% | tagged; STW default |
| 0.5.0 | ~92% | ~82% | pause p50/p99, prof_stats, STW hot-path; chunk release opt-in |
| 0.5.0 + `GCRY_RELEASE_CHUNKS=1` | ~56% | ~49% | opt-in only |
| 0.6.0 | **~105%** | **~100%** | size-class 32 KiB, `notice_reclaim`, chunk index; STW/static-root/stack fixes |
| 0.6.0 + `GCRY_RELEASE_CHUNKS=1` | ~92% | ~92% | opt-in only |
| 0.7.0-dev | — | **~100%** | exact-fit large reuse; empty-chunk munmap outside STW; occupancy stats |
| 0.7.0-dev + `GCRY_RELEASE_CHUNKS=1` | — | **~92%** | same-host `/json` 37838 vs Boehm 40938; default retains ~76 MiB fully-free chunks |
| 0.7.0-dev + `GCRY_CHUNK_BYTES=131072` | — | **~98.5%** | paired `/json` 40516 vs Boehm 41118; RSS ≈ default (empty-chunk waste) |

Same-host raw (2026-07-23, Crystal 1.21, WSL2): Boehm `/` 102154 `/json` 40699 req/s; gcry `/` 107593 `/json` 40653; chunks `/` 94480 `/json` 37547.

## How to record

Same-day gcry + Boehm on both paths → append a row (and refresh README). Do not invent numbers.

```sh
make bench-kemal-wrk   # gcry; Boehm: same binary without -Dgc_none
```
