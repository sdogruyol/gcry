# acikturkiye dogfood (macOS)

**Darwin-only.** Do not fold these into the Linux verdict in [ACIKTURKIYE.md](ACIKTURKIYE.md).

Same app and script as Linux: sibling `../acikturkiye`, `wrk -c 100 -d 30`, `--release`, median-of-3 vs Boehm, post-`/gc-collect` RSS.

## Platform notes

| | |
|--|--|
| Crystal | **≥ 1.21** — rebuild on that toolchain (`gcry` `.tool-versions`) |
| STW | Mach suspend (signal STW under HTTP was ~hang / ~2 req/s) |
| Soft-dirty | N/A |
| Host page | **16 KiB** on Apple Silicon (not 4 KiB) — free-page reclaim must use `sysconf(PAGESIZE)` |
| Free-page RSS | `MADV_DONTNEED` is a no-op for RSS; process default uses `mach_vm_deallocate` + `mach_vm_allocate(FIXED)` |
| Blacklist | Default **off** on Darwin (freelist abandonment grew heaps; `GCRY_BLACKLIST=1` to opt in) |
| Compare | Only same-host Darwin Boehm — never cite vs Linux % |

## Verdict — macOS aarch64 (2026-07-25)

Same host, Crystal 1.21.0, Apple Silicon, `wrk -c 100 -d 30`, median of 3, scrub **off** (`LABEL=macos-aarch64-20260725`):

| | thr (trial median) | post-GC RSS × |
|--|-------------------:|--------------:|
| **gcry vs Boehm** | **~94%** | **~16.6×** |

Throughput matches the Linux-class story. **RSS does not** — far thicker than Linux acikturkiye (~2.8×).

### RSS follow-up (same day, smoke)

After Darwin free-page `mach_vm` reclaim (16 KiB host pages) + blacklist default-off + skip `__DATA_CONST.__const`:

| | thr (15s smoke) | post-GC RSS × (smoke) |
|--|----------------:|----------------------:|
| vs Boehm | ~89% (882 / 989) | **~12.8×** (515 / 40 MiB) |

`free_bytes` after collect dropped (~250 MiB → ~15 MiB resident freelist). **`size_class_live_bytes` still ~700 MiB** — dense conservative live, not empty-chunk waste. Closing toward Linux ~2.8× needs stack maps / less false retention, not more madvise. Re-run median before treating the smoke × as the cut number.

| Trial | thr % Boehm | post-GC RSS × | gcry / Boehm req/s |
|------:|------------:|--------------:|-------------------:|
| 1 | 91.6% | 17.03× | 947 / 1034 |
| 2 | 94.0% | 19.68× | 889 / 946 |
| 3 | 93.6% | 15.64× | 838 / 895 |
| **median** | **94.0%** | **16.63×** | — |

Timeouts: 0 / 0 all trials.

## History (macOS)

| Date / label | thr % | RSS × | Notes |
|--------------|------:|------:|-------|
| 2026-07-24 smoke | — | — | Pre-Mach hang (~2.5 rps) |
| 2026-07-25 `macos-aarch64-20260725` | **~94%** | **~16.6×** | Mach STW; Crystal 1.21.0; median of 3 |
| 2026-07-25 RSS smoke | ~89% | **~12.8×** | `mach_vm` free pages @ 16 KiB; blacklist off; no `__const` roots |

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
