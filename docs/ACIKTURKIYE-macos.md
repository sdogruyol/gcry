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
| Blacklist | Default **off** on Darwin (`GCRY_BLACKLIST=1` to opt in) |
| Conservative scan | Untyped payloads (`type_id ≤ 0`) are **object-base only** |
| Layout builtins | Curated Array/Hash/Deque/`IO::Memory`/`JSON::Any` (not whole-program AUTO) |
| Large mmap | Host-page aligned; Darwin `large_cache_retain` default **0** |
| Compare | Only same-host Darwin Boehm — never cite vs Linux % |

## Verdict (v0.10.0) — macOS aarch64

Same host, Crystal 1.21.0, Apple Silicon, `wrk -c 100 -d 30`, median of 3, scrub **off** (`LABEL=macos-aarch64-v0.10.0`):

| | thr (trial median) | post-GC RSS × |
|--|-------------------:|--------------:|
| **gcry vs Boehm** | **~80%** | **~11.8×** |

Throughput is usable (Mach STW). RSS is not Boehm-class — dense conservative-live (`size_class_live_bytes` ~0.7–0.9 GiB). Free-page reclaim works (`free_bytes` small after collect). **Shard-only heuristics do not close 5×.** Next real win: **compiler stack maps**. Do not average with [ACIKTURKIYE.md](ACIKTURKIYE.md).

| Trial | thr % Boehm | post-GC RSS × | gcry / Boehm req/s |
|------:|------------:|--------------:|-------------------:|
| 1 | 78.8% | 9.36× | 542 / 688 |
| 2 | 81.9% | 12.14× | 584 / 713 |
| 3 | 85.7% | 15.67× | 552 / 645 |
| **median** | **80.3%** | **11.79×** | — |

Timeouts: 0 / 0 all trials.

## History (macOS)

| Date / label | thr % | RSS × | Notes |
|--------------|------:|------:|-------|
| 2026-07-24 smoke | — | — | Pre-Mach hang (~2.5 rps) |
| 2026-07-25 `macos-aarch64-20260725` | **~94%** | **~16.6×** | Mach STW dogfood (pre-polish) |
| 2026-07-25 RSS / polish smoke | ~85–88% | **~10–14×** | `mach_vm` reclaim; layout polish |
| **0.10.0** `macos-aarch64-v0.10.0` | **~80%** | **~11.8×** | Tagged cut; thr/RSS noisy vs toy Kemal |

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
