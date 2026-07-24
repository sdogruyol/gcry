# Kemal wrk vs Boehm

**gcry req/s ÷ Boehm req/s**, same host. Prefer `/json`. Absolute wrk is host-noisy.

Load: `bench/kemal`, `wrk -c 100 -d 30`, fresh process per path, Crystal release (`-Dgc_none` for gcry).

**RSS:** prefer **post-`GC.collect`** (bench exposes `GET /gc-collect`) so end-of-wrk sampling noise does not dominate.

## History

| Version | `/` | `/json` | notes |
|---------|----:|--------:|-------|
| 0.4.0 | ~86% | ~83% | tagged; STW default |
| 0.5.0 | ~92% | ~82% | pause p50/p99, prof_stats, STW hot-path; chunk release opt-in |
| 0.5.0 + `GCRY_RELEASE_CHUNKS=1` | ~56% | ~49% | opt-in only |
| 0.6.0 | **~105%** | **~100%** | size-class 32 KiB, `notice_reclaim`, chunk index; STW/static-root/stack fixes |
| 0.6.0 + `GCRY_RELEASE_CHUNKS=1` | ~92% | ~92% | opt-in only |
| 0.7.0-dev (pre Phase 12) | — | **~100%** | exact-fit large; empty munmap outside STW; chunks retained by default |
| 0.7.0-dev + `GCRY_RELEASE_CHUNKS=1` | — | **~92%** | `/json` 37838 vs Boehm 40938; retained ~76 MiB fully-free chunks |
| 0.7.0-dev + `GCRY_CHUNK_BYTES=131072` | — | **~98.5%** | 40516 vs 41118; RSS ≈ default (empty-chunk waste) |
| **0.7.0-dev Phase 12** | — | **~93%** | empty release **default-on**; base-ptr-only; post-GC RSS **~0.93×** Boehm (median of 5) |

Same-host Phase 12 (2026-07-24, Crystal 1.21, WSL2): five paired `/json` runs — thr median **93.4%** (range 91.7–96.8%); post-GC RSS median **0.93×** (always ≤1.0×). Absolute ~36–38k vs Boehm ~37–41k req/s. `GCRY_KEEP_CHUNKS=1` recovers ~**95%** thr at ~**3×** RSS.

STW SP clamp (2026-07-24, median of 3 `/json`): thr **~93%**; post-GC RSS **~0.93×** — on vs `GCRY_DISABLE_SP_CLAMP=1` is noise (Kemal already Boehm-class RSS).

## How to record

Same-day gcry + Boehm on both paths → append a row (and refresh README). Do not invent numbers.

```sh
make bench-kemal-wrk   # gcry; Boehm: same binary without -Dgc_none
# RSS: after wrk, curl /gc-collect then read VmRSS
```
