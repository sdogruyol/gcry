# Kemal wrk vs Boehm

**gcry req/s ÷ Boehm req/s**, same host. Prefer `/json`. Absolute wrk is host-noisy.

Load: `bench/kemal`, `wrk -c 100 -d 30`, fresh process per path, Crystal release (`-Dgc_none` for gcry).

## History

| Version | `/` | `/json` | notes |
|---------|----:|--------:|-------|
| 0.4.0 | ~86% | ~83% | tagged; STW default |
| 0.5.0 | ~92% | ~82% | pause p50/p99, prof_stats, STW hot-path; chunk release opt-in |
| 0.5.0 + `GCRY_RELEASE_CHUNKS=1` | ~56% | ~49% | opt-in only |
| unreleased | **~105%** | **~100%** | size-class 32 KiB, `notice_reclaim` fast-path, chunk index; STW/static-root/stack fixes |
| unreleased + `GCRY_RELEASE_CHUNKS=1` | ~92% | ~92% | opt-in only |

Same-host raw (2026-07-23, Crystal 1.21, WSL2): Boehm `/` 102154 `/json` 40699 req/s; gcry `/` 107593 `/json` 40653; chunks `/` 94480 `/json` 37547.

## How to record

Same-day gcry + Boehm on both paths → append a row (and refresh README). Do not invent numbers.

```sh
make bench-kemal-wrk   # gcry; Boehm: same binary without -Dgc_none
```
