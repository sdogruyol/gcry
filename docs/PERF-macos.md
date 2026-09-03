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
| Low-water root-scan skip | **Linux-only — Darwin keeps the full scan.** `Platform.stack_low_water` reads `/proc/self/pagemap`; Darwin has no equivalent wired, so the parked-fiber scan still faults its whole lag window. The change that took Kemal EC4 pause 8.06 → 3.60 ms on Linux does **not** apply here |
| Parked-fiber scrub | **Opt-in** (`GCRY_SCRUB_FIBERS=1`), on Darwin as well as Linux. Correctness of the flip is verified on a Darwin host — fuzz / property / soak / OOM / finalizer, both settings — see [SOUND-DEFAULTS.md](SOUND-DEFAULTS.md) § "The flip on Darwin". Every cut in this file *below the 2026-08-10 section* predates the flip and was taken with scrub **on** |

> **Cuts below the 2026-08-10 section were measured under defaults that no
> longer exist**, on both counts in the table above. The Kemal side is now
> re-cut on a Darwin host under current defaults (next section); the fat-app
> headline is **not** — see [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).

## Headline (2026-08-10 — current defaults, Darwin re-cut) — macOS aarch64

Primary: `bench/log/macos/2026-08-10-053800/` (`d36effe`, Crystal 1.21.0, Apple
M2 Pro, Darwin 25.5.0 arm64). Scrub **off** and low-water **absent**, both
confirmed per draw from `/gc-stats` (`fiber_scrub_runs = 0`,
`low_water_skips = 0`) rather than assumed from the defaults.

**Cut at `d36effe`, which was tip when it was taken; tip has since moved.** The
STW watchdog, phase breadcrumbs, the mid-swap guard's counters and the glibc
STW-hang fix all landed after. None of them moves this cut, and the reason is
per-change rather than a blanket claim: the watchdog is default-off (two plain
stores per phase when disarmed), `scrub_force_parked` is default-nil and
research-only, and the `pthread_getattr_np` deadlock the snapshot API exists for
is Linux-only — Darwin's `begin_stack_bounds_snapshot` is a no-op that delegates
to the same `pthread_stack_bounds` this cut already called. Behaviourally the
Darwin default path is unchanged. That is an argument from the diff, not a
measurement: if a Darwin cut at tip is wanted, it has to be run.

To reproduce, take `run_all.sh` from **`f21cdb7` or later**, not from the
`d36effe` in the metadata: at `d36effe` a failed acikturkiye build fell through
to whatever binary was already on disk, and `../acikturkiye` pins its own
Crystal — 1.18.1 there, which cannot build gcry's tip
(`LibC.clock_gettime`). This session was run with those guards applied and
`ASDF_CRYSTAL_VERSION=1.21.0` exported, which is what a sibling on an older pin
needs. The guards touch build and port handling only; nothing they change is
measured.

`wrk -c 100 -d 30`, `--release`, fresh process per path, post-`/gc-collect` RSS.
**n = 9 draws** per cell (`TRIALS=3 COUNT=3`), pooled — not a median-of-3, so
the IQR below is a spread over nine server processes rather than three.

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |
|------|------------------:|-----------------:|--------:|--------------:|
| `/` | 87,001 (IQR 3.5%) | 77,573 (IQR 2.7%) | **89.2%** | **0.96×** |
| `/json` | 61,064 (IQR 0.9%) | 53,590 (IQR 2.2%) | **87.8%** | **0.96×** |

Against the last pre-flip Darwin Kemal cut (`2026-08-04-172842`, scrub on):
`/json` **84.0% → 87.8%**, `/` **90.7% → 89.2%**, RSS flat at Boehm-class both
paths. Two defaults and a commit range moved between those cuts, so read the
deltas as "where the tip sits now", not as an attribution to the flip — the
A/B that isolates the flip is on the fat app, in
[ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md), and it is a wash.

One RSS cell is noisier than it looks: Boehm `/json` RSS carries a 10.2% IQR
against gcry's 0.1%, from two draws that came in at 17.6 MiB instead of 19.6.
The ratio is quoted off medians and is not sensitive to it, but a single Boehm
RSS draw from this host is not.

## Headline (v0.12.0 — in-header MARK default) — macOS aarch64

After **reverting side bitmap as default**, making **in-header MARK the standard**, with **layout scan improvements**, **hash layout scanning**, and **conservative marking fixes**:

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |
|------|------------------:|-----------------:|--------:|--------------:|
| `/` | 92,070 | 78,622 | **85.4%** | **1.34×** |
| `/json` | 66,508 | 57,558 | **86.5%** | **1.36×** |

RSS is now **1.3×** Boehm (down from ~10× in v0.11.0). Throughput is ~85% on both paths — the in-header MARK trades some throughput for a dramatic RSS recovery. The `madvise` syscall storm that caused 132–150 ms STW pauses is gone: all page-release operations run **post-STW**, coalesced into contiguous runs (1 syscall per run instead of 1 per page × up to 64 per chunk).

## Fat-app note (tip / stack-maps)

acikturkiye Darwin tip base closed the old ~18× RSS gate and now runs at
~**98%** thr @ ~**0.97×** RSS (2026-08-14, n = 9 per arm,
`bench/log/macos/2026-08-14-acik-recut/`). Numbers live only in
[ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md) — do **not** fold into Kemal
tables below.

**This replaces the ~0.63× that stood here, and gcry is not what moved.** Same
harness (`acik_stackmap_ab.sh`, two `/gc-collect` passes), same `base` variant,
so it is a replacement rather than a different measurement — which the
2026-08-10 `run_all.sh` cut (0.98×) never was, because that one collects once
and is a different post-GC state. gcry's own post-GC RSS is within **0.6%** of
the 2026-08-04 draws (36,480 → 36,272 KiB); Boehm's fell **35%** (57,568 →
37,392 KiB). The old ratio was in substantial part a statement about that
session's three Boehm draws, and Boehm is the noisy arm here as well —
RSS IQR 16.8% against gcry's 4.5%.

The ~18× gate stays closed. What changes is that gcry is at **parity** with
Boehm on this app, not a third below it. Throughput 89.9% → 98.0% is real at
this n but not attributable: a commit range, the scrub flip and the register fix
all sit between the cuts.

## Headline (tip / stack-maps) — macOS aarch64

Primary: `bench/log/macos/2026-08-04-172842/` (`fda578a`, Crystal 1.21.0, Apple M2 Pro). macOS `gc_override.cr` sets `small_chunk_bytes = 262144` (256 KiB). Scrub on (default). First Darwin Kemal re-cut on tip since v0.17.0.

Kemal median-of-3, `wrk -c 100 -d 30`, `--release`, fresh process per path, post-`/gc-collect` RSS:

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |
|------|------------------:|-----------------:|--------:|--------------:|
| `/` | 87,369 | 79,275 | **90.7%** | **0.95×** |
| `/json` | 62,964 | 52,872 | **84.0%** | **1.01×** |

`/json` **holds** vs v0.17 (**83.6%** → **84.0%**); RSS still Boehm-class (**0.95–1.01×**). Gate is `/json`.

## Headline (v0.17.0) — macOS aarch64

Superseded by tip cut above for tip line. Primary: `bench/log/macos/2026-08-02-085522/` (`18513e0`, Crystal 1.21.0, Apple M2 Pro). Confirm: `2026-08-02-091817/` (`/json` **83.2%**, `/` **89.5%**). First Darwin re-cut since v0.13.0.

Kemal median-of-3, `wrk -c 100 -d 30`, `--release`, fresh process per path, post-`/gc-collect` RSS:

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |
|------|------------------:|-----------------:|--------:|--------------:|
| `/` | 86,579 | 77,575 | **89.6%** | **0.97×** |
| `/json` | 62,769 | 52,454 | **83.6%** | **0.93×** |

`/json` **held** vs v0.13 (**83.9%** → **83.6%**; confirm **83.2%**); RSS at Boehm parity (**0.93–0.97×**).

## Headline (v0.13.0) — macOS aarch64

macOS `gc_override.cr` sets `small_chunk_bytes = 262144` (256 KiB). Superseded by later cuts above.

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

**RSS regression:** the side mark bitmap itself allocates a separate mmap region covering the live heap (1 bit per word-aligned address). For the Kemal workload this adds ~200 MiB of mapped address space on top of the managed heap — hence the ~10× post-GC RSS. This is the explicit price paid for moving mark bits off the object headers; the throughput + latency win more than compensates on HTTP-shaped workloads. That side mapping is gone: mark bitmaps now ride in each chunk's own header (`GCRY_BITMAP=1`, opt-in), so they are mapped and unmapped with the chunk and the RSS tail measured here no longer exists.

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
| **tip** `2026-08-04-172842` | **90.7%** | **84.0%** | **0.95–1.01×** | stack-maps tip (`fda578a`). `/json` hold; RSS still ~1×. |

## How to record (macOS)

```sh
# Crystal 1.21+ on the Mac under test
TRIALS=3 WRK_DURATION=30 bash bench/run_all.sh kemal
# Update THIS file only — not docs/PERF.md
```

Fat-app (macOS): [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).
