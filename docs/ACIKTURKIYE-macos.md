# acikturkiye dogfood (macOS)

**Darwin-only.** Do not fold these into the Linux verdict in [ACIKTURKIYE.md](ACIKTURKIYE.md).

Same app and script as Linux: sibling `../acikturkiye`, `wrk -c 100 -d 30`, `--release`, median-of-3 vs Boehm, post-`/gc-collect` RSS.

## Platform notes

| | |
|--|--|
| Crystal | **≥ 1.21** — rebuild on that toolchain (`gcry` `.tool-versions`) |
| STW | Mach suspend (signal STW under HTTP was ~hang / ~2 req/s) |
| Soft-dirty | N/A |
| Host page | **16 KiB** on Apple Silicon — free-page reclaim uses `sysconf(PAGESIZE)` |
| Free-page RSS | `MADV_DONTNEED` is a no-op; process default uses `mach_vm_deallocate` + `allocate(FIXED)` |
| Blacklist | Default **on** on Darwin (re-enabled in P2.3 era; `GCRY_DISABLE_BLACKLIST=1` to opt out) |
| Conservative scan | Untyped payloads (`type_id ≤ 0`) are **object-base only** |
| Layout builtins | Curated Array/Hash/Deque/`IO::Memory`/`JSON::Any` (not whole-program AUTO) |
| Large mmap | Host-page aligned; Darwin `large_cache_retain` starts at **1 MiB** (adaptive LRU) |
| Free-page release | Walks ALL kept size-class chunks on Darwin (not just HOLED) for aggressive RSS recovery |
| Compare | Only same-host Darwin Boehm — never cite vs Linux % |

## Verdict (v0.10.0) — macOS aarch64

Same host, Crystal 1.21.0, Apple Silicon, `wrk -c 100 -d 30`, median of 3, scrub **off** (`LABEL=macos-aarch64-v0.10.0`):

| | thr (trial median) | post-GC RSS × |
|--|-------------------:|--------------:|
| **gcry vs Boehm** | **~80%** | **~11.8×** |

Throughput is usable (Mach STW). RSS is not Boehm-class — dense conservative-live (`size_class_live_bytes` ~0.7–0.9 GiB). Free-page reclaim works (`free_bytes` small after collect). **Shard-only heuristics do not close 5×.** Next real win: **compiler stack maps**. Do not average with [ACIKTURKIYE.md](ACIKTURKIYE.md).

## Current benchmark (2026-07-27, `6416ad6`, v0.12.0-8-g6416ad6) — macOS aarch64

Small chunk 128 KiB, fiber scrub enabled, plugged in. Median-of-3, `wrk -c 100 -d 30`, `--release`:

| Trial | Boehm req/s | gcry req/s | % Boehm | Boehm RSS (KiB) | gcry RSS (KiB) | RSS × |
|------:|-----------:|----------:|-------:|----------------:|---------------:|------:|
| 1 | 952 | 587 | 61.7% | 27,968 | 637,056 | 22.78× |
| 2 | 920 | 562 | 61.1% | 46,800 | 595,536 | 12.73× |
| 3 | 959 | 590 | 61.6% | 36,368 | 648,288 | 17.83× |
| **median** | 952 | 587 | **61.7%** | 36,368 | 637,056 | **17.52×** |

Throughput at ~62% Boehm. RSS varies 12.7–22.8× across trials (conservative live set dominates at ~560 MiB `size_class_live_bytes`). Small chunk 128 KiB reduces fragmentation but increases collection count (~275 majors in 30s).

## History (macOS)

| Date / label | thr % | RSS × | Notes |
|--------------|------:|------:|-------|
| 2026-07-24 smoke | — | — | Pre-Mach hang (~2.5 rps) |
| 2026-07-25 `macos-aarch64-20260725` | **~94%** | **~16.6×** | Mach STW dogfood (pre-polish) |
| 2026-07-25 RSS / polish smoke | ~85–88% | **~10–14×** | `mach_vm` reclaim; layout polish |
| **0.10.0** `macos-aarch64-v0.10.0` | **~80%** | **~11.8×** | Tagged cut; thr/RSS noisy vs toy Kemal |
| **2026-07-25** `unreleased-darwin` | **75.3%** | **30.3×** | P2.1+P2.2+P2.3; RSS spike from ~11× to ~30× on Darwin — conservative live grows with layout changes |
| **2026-07-26** `rss-yak-darwin` | **73.7%** | **26.8×** | Blacklist re-enable + aggressive madvise + LRU cache + bitmap headroom 12.5%; slight RSS improvement, throughput cost from blacklist |
| **0.12.0** `in-header-mark` | **76.7%** | **22.3×** | Reverted side bitmap → in-header MARK default; RSS improved 2.6× vs prior session, throughput ~77% |
| **v0.13.0** `darwin-rss-tuning` | **78.0%** | **22.1×** | `empty_chunk_retain` 512KB (was 8MB), `scrub_fibers_enabled=true`, `gc_threshold` 16MB, large-freelist `MADV_FREE_REUSABLE`. Kemal RSS dropped from ~160 MiB to ~18 MiB (1.04× Boehm); ACIKTURKIYE ~700 MiB steady (conservative live set still dominant). Pause halved (47→25 ms). |
| | **2026-07-27** `6416ad6` | **61.7%** | **17.5×** | Small chunk 128 KiB, fiber scrub. RSS improved from 22× to 17.5×; throughput dropped to ~62% (more collections from smaller chunks). |

## How to measure

```sh
# Crystal 1.21+
cd ../acikturkiye
ACIKTURKIYE_ENV=demo crystal build -Dgc_none --release src/acikturkiye.cr -o bin/acikturkiye-gcry
ACIKTURKIYE_ENV=demo crystal build --release src/acikturkiye.cr -o bin/acikturkiye-boehm
LABEL=macos-aarch64-$(date +%Y%m%d) ../gcry/bench/median_acikturkiye_boehm.sh
# Update THIS file only
```

Toy Kemal (macOS): [PERF-macos.md](PERF-macos.md).
