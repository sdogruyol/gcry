# acikturkiye dogfood (macOS)

**Darwin-only.** Do not fold these into the Linux verdict in [ACIKTURKIYE.md](ACIKTURKIYE.md).

Same app and script as Linux: sibling `../acikturkiye`, `wrk -c 100 -d 30`, `--release`, median-of-3 vs Boehm, post-`/gc-collect` RSS.

## Platform notes

| | |
|--|--|
| Crystal | **≥ 1.21** — rebuild on that toolchain (`gcry` `.tool-versions`) |
| STW | Mach suspend (signal STW under HTTP was ~hang / ~2 req/s) |
| Soft-dirty | N/A |
| Compare | Only same-host Darwin Boehm — never cite vs Linux % |

## Verdict — macOS aarch64 (2026-07-25)

Same host, Crystal 1.21.0, Apple Silicon, `wrk -c 100 -d 30`, median of 3, scrub **off** (`LABEL=macos-aarch64-20260725`):

| | thr (trial median) | post-GC RSS × |
|--|-------------------:|--------------:|
| **gcry vs Boehm** | **~94%** | **~16.6×** |

Throughput matches the Linux-class story. **RSS does not** — far thicker than Linux acikturkiye (~2.8×). Treat Darwin fat-app RSS as an open platform gap (Mach STW / dyld roots / `madvise` reclaim); do not average with [ACIKTURKIYE.md](ACIKTURKIYE.md).

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
