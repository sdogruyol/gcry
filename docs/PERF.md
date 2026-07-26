# Performance vs Boehm (Linux)

**Canonical cut numbers for version bumps live here (Linux only).** macOS: [PERF-macos.md](PERF-macos.md).

**One number:** `gcry req/s ÷ Boehm req/s` on the same host. Prefer **`/json`**. Absolute wrk is noise; **% of Boehm** is the score.

Load: `bench/kemal`, `wrk -c 100 -d 30`, fresh process per path, `--release` (`-Dgc_none` for gcry).

**RSS:** after wrk, `GET /gc-collect`, then read process RSS (`ps` / VmRSS) — end-of-run noise otherwise dominates.

## Headline (Unreleased) — Linux

Same host, Crystal 1.21, WSL2 x86_64, median of 3, pure `--release`, **in-header MARK** (default), scrub **off**, auto-layouts **off**. Session: `bench/log/2026-07-26-173602/`.

| Path | % of Boehm | post-GC RSS × |
|------|----------:|--------------:|
| `/json` | **~89%** | **~0.99×** |
| `/` | **~90%** | **~0.99×** |

Alloc-heavy `/json` is the gate. Idle `/` is sanity. Near-Boehm thr and RSS again after reverting side-bitmap as default.

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |
|------|------------------:|-----------------:|-------:|--------------:|
| `/` | 83891 | 75797 | **90.4%** | **0.99×** |
| `/json` | 37675 | 33450 | **88.8%** | **0.99×** |

`GCRY_KEEP_CHUNKS=1` was last measured in the 0.9 era (~**95%** `/json` @ ~**3×** RSS) — re-measure before citing against this cut. Soft-dirty nursery stays opt-in (HTTP too dirty for a win). Side bitmap: `-Dgcry_side_bitmap` (see escape table).

## History (Linux)

Kemal `% of Boehm` on `/` and `/json`. Prefer `/json` when reading the arc. RSS column is post-`GC.collect` where recorded.

| Version | `/` | `/json` | RSS × | What changed |
|---------|----:|--------:|------:|--------------|
| 0.4.0 | ~86% | ~83% | — | STW default |
| 0.5.0 | ~92% | ~82% | — | pause p50/p99; STW hot path; chunk release still opt-in |
| 0.6.0 | **~105%** | **~100%** | — | size-class 32 KiB, `notice_reclaim`, chunk index, STW/root fixes |
| 0.7.0 | ~92% | ~90% | **~0.93×** | empty-chunk release **default-on**; layout / type_id / SP clamp |
| 0.8.0 | ~91% | ~89% | **~0.93×** | barriers, TLAB, blacklist, atfork, aarch64, metrics |
| **0.9.0** | **~89%** | **~92%** | **~0.97×** | stack scrub (opt-in); parallel-mark experimental; observability |
| 0.10.0 | *(carry 0.9.0)* | *(carry 0.9.0)* | *(carry)* | **macOS process GC** — Linux not re-cut this release; see [PERF-macos.md](PERF-macos.md) |
| 0.11.0 | *(carry 0.9.0)* | *(carry 0.9.0)* | *(carry)* | side mark bitmap landed on Darwin host; Linux not re-cut at tag |
| Unreleased (bitmap) | ~78% | ~82% | ~9.2× | Linux A/B with side bitmap still default (`2026-07-26-171942`) |
| **Unreleased** | **~90%** | **~89%** | **~0.99×** | in-header MARK default again; side bitmap opt-in (`-Dgcry_side_bitmap`) |

**Escape knobs (same era, not defaults):**

| Config | `/` | `/json` | RSS × | Note |
|--------|----:|--------:|------:|------|
| 0.5.0 + `GCRY_RELEASE_CHUNKS=1` | ~56% | ~49% | — | release too early to be default |
| 0.6.0 + `GCRY_RELEASE_CHUNKS=1` | ~92% | ~92% | — | thr cost for RSS |
| 0.7-dev + keep chunks | — | ~100% | high | empty retain ≈ waste |
| 0.7-dev Phase 12 (pre-tag) | — | ~93% | ~0.93× | release default-on landed |
| `GCRY_KEEP_CHUNKS=1` (0.9 era) | — | ~**95%** | ~**3×** | thr↑ RSS↑ escape — re-measure on Unreleased |
| `-Dgcry_side_bitmap` (Unreleased A/B) | **~78%** | **~82%** | **~9.2×** | side mmap marks; see `bench/log/bitmap-ab/FINDINGS.txt` |

Detail tables for 0.7–0.9 cuts lived in git history / CHANGELOG; headline numbers above are the ones to cite. Fat-app (Linux): [ACIKTURKIYE.md](ACIKTURKIYE.md).

## Pauses

`Gcry.pause_stats` — ring of last 64 STW pauses: `last_ns`, `p50_ns`, `p99_ns`, `max_ns`, `total_ns`, `count`.

Default process GC = **full STW majors**. `GCRY_INCREMENTAL=1` + a dirty barrier can re-scan pages before sweep; nursery (`GCRY_NURSERY`) stays off for process HTTP unless you are measuring p99. Soft-dirty is **Linux-only**.

## How to record (Linux)

Same-day gcry + Boehm, both paths → update **this** file and the README Linux table. Do **not** overwrite these tables with macOS wrk — use [PERF-macos.md](PERF-macos.md).

```sh
make bench-kemal-wrk
LABEL=linux-$(date +%Y%m%d) ./bench/median_kemal_boehm.sh
LABEL=linux-$(date +%Y%m%d) ./bench/median_acikturkiye_boehm.sh
# or: GC=both COUNT=1 TRIALS=3 bash bench/run_all.sh all
# after wrk: curl …/gc-collect && read RSS
```
