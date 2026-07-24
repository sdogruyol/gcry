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
| 0.7.0-dev Phase 12 | — | **~93%** | empty release **default-on**; base-ptr-only; post-GC RSS **~0.93×** Boehm (median of 5) |
| **0.7.0** | **~92%** | **~90%** | Phase 12 defaults + layout / root type_id / STW SP clamp; post-GC RSS **~0.93×** (median of 3) |
| **0.8.0** | **~91%** | **~89%** | Barriers/TLAB/blacklist/layouts/atfork/aarch64/metrics; post-GC RSS **~0.93×** (median of 3) |

Same-host **0.8.0** (2026-07-24, Crystal 1.21, WSL2): three paired runs per path, fresh release binaries.

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |
|------|------------------:|-----------------:|-------:|--------------:|
| `/` | 88905 | 80604 | **90.7%** | **0.93×** |
| `/json` | 39801 | 35253 | **88.6%** | **0.93×** |

Same-host **0.7.0** (2026-07-24, Crystal 1.21, WSL2): three paired runs per path.

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |
|------|------------------:|-----------------:|-------:|--------------:|
| `/` | 83619 | 76526 | **91.5%** | **0.94×** |
| `/json` | 41191 | 37186 | **90.3%** | **0.93×** |

`GCRY_KEEP_CHUNKS=1` still trades thr (~**95%**) for ~**3×** RSS. Soft-dirty nursery stays opt-in.

## Pause histogram (shard API)

`Gcry.pause_stats` / `Heap#pause_percentile_ns` expose a ring of the last 64 STW pauses:

| Field | Meaning |
|-------|---------|
| `last_ns` / `max_ns` / `total_ns` / `count` | Latest, peak, sum, sample count |
| `p50_ns` / `p99_ns` | Nearest-rank percentiles over the ring |

With a page-dirty barrier (`soft_dirty` or `mprotect`) and `GCRY_INCREMENTAL=1`, slices re-scan dirty pages before sweep so incremental termination is sounder than plain SATB without barriers. Nursery (`GCRY_NURSERY`) still defaults **off** for process GC (dirty HTTP heaps fall back to full old→young and raise pause); enable when measuring p99.

```sh
# After a run under -Dgc_none:
#   Gcry.pause_stats.p99_ns
```

## How to record

Same-day gcry + Boehm on both paths → append a row (and refresh README). Do not invent numbers.

```sh
make bench-kemal-wrk   # gcry; Boehm: same binary without -Dgc_none
# RSS: after wrk, curl /gc-collect then read VmRSS
```
