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

## Verdict (tip / stack-maps) — macOS aarch64

Primary: `bench/log/macos/2026-08-04-acik-stackmap/` (`75a9d25` + Darwin Mach-O/aarch64 stackmap walker). Tip Crystal probe `4a965f423`, system Boehm Crystal 1.21.0, Apple M2 Pro. `acik_stackmap_ab.sh` med-of-3, `wrk -c 100 -d 30`, dual `/gc-collect`, 0 Non-2xx.

| | thr (trial median) | post-GC RSS × |
|--|-------------------:|--------------:|
| **gcry tip base vs Boehm** | **~90%** | **~0.63×** |

Closes the v0.17 **~18×** Darwin RSS gate on the **product path** (no `PRECISE_STACK`). Live_sc ~6–9 MiB post-GC (was ~1.1 GiB dense false-live). Stackmap hybrid/exclusive load maps and mark roots but **do not** beat tip base RSS (~0.86–1.27×) — research only; see [FINDINGS](../bench/log/macos/2026-08-04-acik-stackmap/FINDINGS.md). Do not average with [ACIKTURKIYE.md](ACIKTURKIYE.md).

### Trial detail (tip base, 2026-08-04)

| Trial | Boehm req/s | gcry base req/s | % Boehm | Boehm RSS (KiB) | base RSS (KiB) | RSS × |
|------:|-----------:|----------------:|-------:|----------------:|---------------:|------:|
| 1 | 1036 | 920 | **88.9%** | 63,856 | 47,120 | 0.74× |
| 2 | 999 | 903 | **90.4%** | 57,568 | 34,912 | 0.61× |
| 3 | 1004 | 874 | **87.1%** | 55,344 | 36,480 | 0.66× |
| **median** | 1004 | 903 | **89.9%** | 57,568 | 36,480 | **0.63×** |

## Verdict (v0.17.0) — macOS aarch64

Superseded by tip cut above for RSS. Primary (fair Boehm): `bench/log/macos/2026-08-02-085522/` (`18513e0`). Confirm: `2026-08-02-091817/` (soft/noisy Boehm → inflated %). `small_chunk_bytes` = 262144 in `gc_override.cr` (Darwin only). Median-of-3, `wrk -c 100 -d 30`, `--release`, scrub on, 0 crashes.

| | thr (trial median) | post-GC RSS × |
|--|-------------------:|--------------:|
| **gcry vs Boehm** | **~71%** | **~18.4×** |

Throughput usable (Mach STW). **Thr softer** than v0.13 **~78%** (−7pp); Boehm louder (~955 vs ~921) and gcry abs lower (~675 vs ~718). Confirm session gcry abs ~650–680 but Boehm soft (654–849) → **89%** — do not cite that %; keep this fair cut for the **tagged** v0.17 line. RSS was dense conservative-live (~1.1 GiB) — fixed on tip by finalizer/registry work, not by enabling stackmaps.

### Trial detail (v0.17.0)

| Trial | Boehm req/s | gcry req/s | % Boehm | Boehm RSS (KiB) | gcry RSS (KiB) | RSS × |
|------:|-----------:|----------:|-------:|----------------:|---------------:|------:|
| 1 | 955 | 680 | **71.1%** | 28,784 | 631,424 | 21.94× |
| 2 | 960 | 675 | **70.4%** | 34,928 | 632,752 | 18.12× |
| 3 | 952 | 674 | **70.9%** | 34,352 | 588,544 | 17.13× |
| **median** | 955 | 675 | **70.7%** | 34,352 | 631,424 | **18.38×** |

~497 majors / 30s; pause p50 ~26 ms. Live set unchanged vs v0.13 cut.

## Verdict (v0.13.0) — macOS aarch64

Superseded by tip cut above.

| | thr (trial median) | post-GC RSS × |
|--|-------------------:|--------------:|
| **gcry vs Boehm** | **~78%** | **~15.8×** |

### Trial detail (256 KiB chunk, v0.13)

| Trial | Boehm req/s | gcry req/s | % Boehm | Boehm RSS (KiB) | gcry RSS (KiB) | RSS × |
|------:|-----------:|----------:|-------:|----------------:|---------------:|------:|
| 1 | 932 | 725 | **77.8%** | 39,392 | 635,968 | 16.14× |
| 2 | 919 | 718 | **78.1%** | 35,488 | 612,592 | 17.26× |
| 3 | 921 | 670 | **72.7%** | 38,752 | 588,192 | 15.18× |
| **median** | 921 | 718 | **77.9%** | 38,752 | 612,592 | **15.81×** |

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
| | **2026-07-27** `256k-chunk` | **77.9%** | **15.8×** | **macOS default → 256 KiB chunk** (`gc_override.cr`). Thr recovers to ~78% Boehm (up from 62%). RSS unchanged at ~16×. 0 crashes. |
| **0.17.0** `2026-08-02-085522` | **70.7%** | **18.4×** | First Darwin re-cut since v0.13 (`18513e0`). Thr −7pp vs 256k cut; RSS ~18× (live set). 0 crashes. Fair Boehm ~955. |
| 0.17 confirm `2026-08-02-091817` | *89.4%* | **16.7×** | Soft/noisy Boehm (654–849); gcry abs ~650–680. **Do not cite %** — keep 085522. |
| **tip** `2026-08-04-acik-stackmap` | **89.9%** | **0.63×** | stack-maps tip base (finalizer era). Stackmap exclusive/hybrid not RSS-better. |

## How to measure

```sh
# Crystal 1.21+ (sibling ../acikturkiye with .env.demo)
TRIALS=3 WRK_DURATION=30 bash bench/run_all.sh acik
# Update THIS file only
```

Toy Kemal (macOS): [PERF-macos.md](PERF-macos.md).
