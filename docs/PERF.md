# Performance vs Boehm

**One number:** `gcry req/s ÷ Boehm req/s` on the same host. Prefer **`/json`**. Absolute wrk is noise; **% of Boehm** is the score.

Load: `bench/kemal`, `wrk -c 100 -d 30`, fresh process per path, `--release` (`-Dgc_none` for gcry).

**RSS:** after wrk, `GET /gc-collect`, then read VmRSS — end-of-run noise otherwise dominates.

## Headline (v0.9.0)

Same host, Crystal 1.21, WSL2, median of 3, scrub **off**:

| Path | % of Boehm | post-GC RSS × |
|------|----------:|--------------:|
| `/json` | **~92%** | **~0.97×** |
| `/` | **~89%** | **~0.97×** |

Near Boehm on the alloc-heavy path. Idle `/` is sanity, not the gate.

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |
|------|------------------:|-----------------:|-------:|--------------:|
| `/` | 92922 | 82494 | **88.8%** | **0.97×** |
| `/json` | 40162 | 36878 | **91.8%** | **0.97×** |

`GCRY_KEEP_CHUNKS=1` → ~**95%** `/json` thr @ ~**3×** RSS. Soft-dirty nursery stays opt-in (HTTP too dirty for a win).

## History

Kemal `% of Boehm` on `/` and `/json`. Prefer `/json` when reading the arc. RSS column is post-`GC.collect` where recorded.

| Version | `/` | `/json` | RSS × | What changed |
|---------|----:|--------:|------:|--------------|
| 0.4.0 | ~86% | ~83% | — | STW default |
| 0.5.0 | ~92% | ~82% | — | pause p50/p99; STW hot path; chunk release still opt-in |
| 0.6.0 | **~105%** | **~100%** | — | size-class 32 KiB, `notice_reclaim`, chunk index, STW/root fixes |
| 0.7.0 | ~92% | ~90% | **~0.93×** | empty-chunk release **default-on**; layout / type_id / SP clamp |
| 0.8.0 | ~91% | ~89% | **~0.93×** | barriers, TLAB, blacklist, atfork, aarch64, metrics |
| **0.9.0** | **~89%** | **~92%** | **~0.97×** | stack scrub (opt-in); parallel-mark experimental; observability |

**Escape knobs (same era, not defaults):**

| Config | `/` | `/json` | RSS × | Note |
|--------|----:|--------:|------:|------|
| 0.5.0 + `GCRY_RELEASE_CHUNKS=1` | ~56% | ~49% | — | release too early to be default |
| 0.6.0 + `GCRY_RELEASE_CHUNKS=1` | ~92% | ~92% | — | thr cost for RSS |
| 0.7-dev + keep chunks | — | ~100% | high | empty retain ≈ waste |
| 0.7-dev Phase 12 (pre-tag) | — | ~93% | ~0.93× | release default-on landed |
| `GCRY_KEEP_CHUNKS=1` (current) | — | ~**95%** | ~**3×** | thr↑ RSS↑ escape |

Detail tables for 0.7–0.9 cuts lived in git history / CHANGELOG; headline numbers above are the ones to cite. Fat-app: [ACIKTURKIYE.md](ACIKTURKIYE.md).

## Pauses

`Gcry.pause_stats` — ring of last 64 STW pauses: `last_ns`, `p50_ns`, `p99_ns`, `max_ns`, `total_ns`, `count`.

Default process GC = **full STW majors**. `GCRY_INCREMENTAL=1` + a dirty barrier can re-scan pages before sweep; nursery (`GCRY_NURSERY`) stays off for process HTTP unless you are measuring p99.

## How to record

Same-day gcry + Boehm, both paths → update this file and the README table.

```sh
make bench-kemal-wrk
./bench/median_kemal_boehm.sh          # median-of-3 vs Boehm
./bench/median_acikturkiye_boehm.sh    # dogfood
# after wrk: curl …/gc-collect && read VmRSS
```
