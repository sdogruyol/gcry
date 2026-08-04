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

## Headline (v0.12.0 — in-header MARK default) — macOS aarch64

After **reverting side bitmap as default**, making **in-header MARK the standard**, with **layout scan improvements**, **hash layout scanning**, and **conservative marking fixes**:

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |
|------|------------------:|-----------------:|--------:|--------------:|
| `/` | 92,070 | 78,622 | **85.4%** | **1.34×** |
| `/json` | 66,508 | 57,558 | **86.5%** | **1.36×** |

RSS is now **1.3×** Boehm (down from ~10× in v0.11.0). Throughput is ~85% on both paths — the in-header MARK trades some throughput for a dramatic RSS recovery. The `madvise` syscall storm that caused 132–150 ms STW pauses is gone: all page-release operations run **post-STW**, coalesced into contiguous runs (1 syscall per run instead of 1 per page × up to 64 per chunk).

## Fat-app note (tip / stack-maps)

acikturkiye Darwin tip base closed the old ~18× RSS gate (~**90%** thr @
~**0.63×** RSS). Numbers live only in [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md)
/ `bench/log/macos/2026-08-04-acik-stackmap/` — do **not** fold into Kemal
tables below. Kemal headline on this file is still the v0.17 cut until a fresh
`bench/run_all.sh` Kemal med3 on tip.

## Headline (v0.17.0) — macOS aarch64

Primary: `bench/log/macos/2026-08-02-085522/` (`18513e0`, Crystal 1.21.0, Apple M2 Pro). Confirm: `2026-08-02-091817/` (`/json` **83.2%**, `/` **89.5%**). macOS `gc_override.cr` sets `small_chunk_bytes = 262144` (256 KiB). Scrub on (default). First Darwin re-cut since v0.13.0.

Kemal median-of-3, `wrk -c 100 -d 30`, `--release`, fresh process per path, post-`/gc-collect` RSS:

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |
|------|------------------:|-----------------:|--------:|--------------:|
| `/` | 86,579 | 77,575 | **89.6%** | **0.97×** |
| `/json` | 62,769 | 52,454 | **83.6%** | **0.93×** |

`/json` **holds** vs v0.13 (**83.9%** → **83.6%**; confirm **83.2%**); RSS still at Boehm parity (**0.93–1.07×**). Idle `/` soft (−3pp) — host noise; gate is `/json`.

## Headline (v0.13.0) — macOS aarch64

macOS `gc_override.cr` sets `small_chunk_bytes = 262144` (256 KiB). Superseded by v0.17.0 cut above.

Kemal median-of-3, `wrk -c 100 -d 30`, `--release`, fresh process per path, post-`/gc-collect` RSS:

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |
|------|------------------:|-----------------:|--------:|--------------:|
| `/` | 87,115 | 80,675 | **92.6%** | **1.06×** |
| `/json` | 64,159 | 53,817 | **83.9%** | **0.93×** |

GCry RSS essentially at Boehm parity (0.93–1.06×). Throughput at 93% `/` and 84% `/json` — unchanged from the 128 KiB regime.

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

## Headline (v0.11.0) — macOS aarch64

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
| **Unreleased** `macos-aarch64-20260725` | **~104%** | **~96%** | **~5–7×** | Bitmap shrink + deferred madvise; RSS halved, no hang, coalesced syscalls |
  | **2026-07-25** `unreleased-darwin` | **104.8%** | **94.3%** | **4.76×** | P2.1+P2.2+P2.3; `/json` steady ~94%, `/` >104% variance |
  | **2026-07-26** `rss-yak-darwin` | **102.2%** | **79.7%** | **n/a** | P3.3 (LRU cache) + blacklist re-enable + aggressive madvise; `/json` dropped to ~80% — blacklist default-on adds root-scan cost on Darwin |
  | **0.12.0** `in-header-mark` | **85.4%** | **86.5%** | **1.34–1.36×** | Reverted side bitmap → in-header MARK default; RSS dropped from ~10× to ~1.3×, throughput settled at ~85% both paths |
  | **v0.13.0** `darwin-rss-tuning` | **90.3%** | **82.6%** | **1.04–1.05×** | `empty_chunk_retain` 512KB, `scrub_fibers_enabled=true`, `gc_threshold` 16MB, large-freelist `MADV_FREE_REUSABLE`. Kemal RSS at near-Boehm parity; `/json` ~82% thr due to more frequent collections. |
|  | **2026-07-27** `6416ad6` | **92.1%** | **85.5%** | **0.75–0.88×** | Small chunk 128 KiB, fiber scrub on. GCry RSS below Boehm on both paths. |
|  | **2026-07-27** `256k-chunk` | **92.6%** | **83.9%** | **0.93–1.06×** | **macOS default → 256 KiB chunk** (`gc_override.cr`). acikturkiye thr recovers 57%→78% with same RSS. Kemal flat. |
| **0.17.0** `2026-08-02-085522` | **89.6%** | **83.6%** | **0.93–0.97×** | First Darwin re-cut since v0.13 (`18513e0`). `/json` hold; `/` soft −3pp. |
| 0.17 confirm `2026-08-02-091817` | **89.5%** | **83.2%** | **0.99–1.07×** | Same-day confirm; Kemal hold. |

## How to record (macOS)

```sh
# Crystal 1.21+ on the Mac under test
TRIALS=3 WRK_DURATION=30 bash bench/run_all.sh kemal
# Update THIS file only — not docs/PERF.md
```

Fat-app (macOS): [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).
