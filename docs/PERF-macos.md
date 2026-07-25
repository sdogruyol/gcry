# Performance vs Boehm (macOS)

**Darwin-only.** Do not merge these numbers into the Linux cut tables in [PERF.md](PERF.md) or the README headline.

Same methodology as Linux: `% of Boehm` = `gcry req/s ÷ Boehm req/s`, same host, `wrk -c 100 -d 30`, `--release`, fresh process per path, post-`GET /gc-collect` RSS via `ps`.

## Platform notes

| | |
|--|--|
| Crystal | **≥ 1.21** (asdf: repo `.tool-versions`) — older toolchains hang under HTTP STW |
| STW | Mach `thread_suspend` / `thread_resume` (not Linux signals) |
| Soft-dirty / nursery barrier | N/A — majors stay full STW |
| CI | `macos-latest` correctness only — **not** a thr gate |

## Headline — macOS aarch64 (2026-07-25)

Same host, Crystal 1.21.0, Apple Silicon, median of 3, scrub **off** (`LABEL=macos-aarch64-20260725`):

| Path | % of Boehm | post-GC RSS × |
|------|----------:|--------------:|
| `/json` | **~91%** | **~0.93×** |
| `/` | **~94%** | **~0.90×** |

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |
|------|------------------:|-----------------:|-------:|--------------:|
| `/` | 89553 | 84503 | **94.4%** | **0.90×** |
| `/json` | 65159 | 59069 | **90.7%** | **0.93×** |

Prefer **`/json`** when asking “did GC get better?” on Darwin. Absolute wrk is not comparable to Linux [PERF.md](PERF.md).

## History (macOS)

| Date / label | `/` | `/json` | RSS × | Notes |
|--------------|----:|--------:|------:|-------|
| 2026-07-25 `macos-aarch64-20260725` | **~94%** | **~91%** | **~0.90–0.93×** | Mach STW; Crystal 1.21.0; median of 3 |

## How to record (macOS)

```sh
# Crystal 1.21+ on the Mac under test
LABEL=macos-aarch64-$(date +%Y%m%d) ./bench/median_kemal_boehm.sh
# Update THIS file only — not docs/PERF.md
```

Fat-app (macOS): [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).
