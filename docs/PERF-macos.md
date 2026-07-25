# Performance vs Boehm (macOS)

**Darwin-only.** Do not merge these numbers into the Linux cut tables in [PERF.md](PERF.md) or treat them as the Linux README headline.

Same methodology as Linux: `% of Boehm` = `gcry req/s ÷ Boehm req/s`, same host, `wrk -c 100 -d 30`, `--release`, fresh process per path, post-`GET /gc-collect` RSS via `ps`.

## Platform notes

| | |
|--|--|
| Crystal | **≥ 1.21** (asdf: repo `.tool-versions`) — older toolchains hang under HTTP STW |
| STW | Mach `thread_suspend` / `thread_resume` (not Linux signals) |
| Soft-dirty / nursery barrier | N/A — majors stay full STW |
| Host page | **16 KiB** on Apple Silicon — large mmap + free-page reclaim use `host_page_size` |
| CI | `macos-latest` correctness only — **not** a thr gate |

## Headline (v0.10.0) — macOS aarch64

Same host, Crystal 1.21.0, Apple Silicon, median of 3, scrub **off** (`LABEL=macos-aarch64-v0.10.0`):

| Path | % of Boehm | post-GC RSS × |
|------|----------:|--------------:|
| `/json` | **~90%** | **~0.97×** |
| `/` | **~97%** | **~0.96×** |

Near Boehm on both paths. Prefer **`/json`** when asking “did GC get better?” Absolute wrk is not comparable to Linux [PERF.md](PERF.md).

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |
|------|------------------:|-----------------:|-------:|--------------:|
| `/` | 69686 | 67237 | **96.5%** | **0.96×** |
| `/json` | 62996 | 56655 | **89.9%** | **0.97×** |

## Headline (Unreleased) — macOS aarch64

After the **side mark bitmap** + **`empty_chunk_retain = 64 MiB`** rework on top of v0.10.0:

| Path | Boehm req/s | gcry req/s | % Boehm | p50 lat | p99 lat | post-GC RSS × |
|------|------------:|-----------:|--------:|--------:|--------:|--------------:|
| `/` | 88035 | 87867 | **99.8%** | 1.70 ms | 2.71 ms | **~10×** |
| `/json` | 63087 | 59437 | **94.2%** | 2.28 ms | 2.81 ms | **~10×** |

Latency dropped **−87% on `/json`** (18 ms → 2.3 ms) and **−95% on `/`** (14 ms → 1.7 ms); p99 latency is now within 2× of Boehm on both paths.

**RSS regression:** the side mark bitmap itself allocates a separate mmap region covering the live heap (1 bit per word-aligned address). For the Kemal workload this adds ~200 MiB of mapped address space on top of the managed heap — hence the ~10× post-GC RSS. This is the explicit price paid for moving mark bits off the object headers; the throughput + latency win more than compensates on HTTP-shaped workloads. RSS recovery options: tighten `ensure_bitmap_covers` to track the actual used heap range (currently keeps headroom for one chunk of growth), or share bitmap pages with the kernel page cache.

## History (macOS)

| Date / label | `/` | `/json` | RSS × | Notes |
|--------------|----:|--------:|------:|-------|
| 2026-07-25 `macos-aarch64-20260725` | **~94%** | **~91%** | **~0.90–0.93×** | Mach STW dogfood (pre-tag) |
| **0.10.0** `macos-aarch64-v0.10.0` | **~97%** | **~90%** | **~0.96–0.97×** | First tagged macOS process GC cut |
| **0.11.0** `macos-aarch64-v0.11.0` | **~100%** | **~94%** | **~10×** | Side mark bitmap + retain 64 MiB; throughput + latency parity, RSS regression from bitmap pages |

## How to record (macOS)

```sh
# Crystal 1.21+ on the Mac under test
LABEL=macos-aarch64-$(date +%Y%m%d) ./bench/median_kemal_boehm.sh
# Update THIS file only — not docs/PERF.md
```

Fat-app (macOS): [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).
