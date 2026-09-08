# What the default heuristics cost — re-cut on the 0.24.x bitmap default

Date: 2026-09-08 · host: AMD Ryzen AI 9 465 (Zen 5, 20 threads), Linux 7.2.2
Tree `bc2e035` (0.24.1 + #40 + the SVE `range_any` change) · Crystal 1.21.0
`bench/performance/kemal_ab.py`, Kemal `/json`, **20 rotated rounds × 7 arms**,
15 s per trial after warmup, `wrk -t4 -c100`, identical-binary null control.
`arms.json`, `manifest.json`, `trials.jsonl`, `analysis_*.txt` beside this file.

## Why

Every number in README § "What the default heuristics cost" and the pause
table was measured on the freelist allocator (2026-08-06 / 2026-08-09,
i3-12100F, WSL2). 0.24.0 made the bitmap allocator the process default and
nothing in that section had been re-read against it.

## Arms

| arm | build | env |
|---|---|---|
| boehm | `--release` | — |
| null | same binary as boehm | — |
| tuned | `-Dgc_none` | process defaults (heuristics armed) |
| sound | `-Dgc_none` | `GCRY_SOUND=1` |
| sound_cons | `-Dgc_none` | `GCRY_SOUND=1 GCRY_DISABLE_LAYOUT=1` |
| tuned_ec4 | `-Dgc_none -Dpreview_mt -Dexecution_context` | `EC_PARALLELISM=4` |
| sound_ec4 | same | `EC_PARALLELISM=4 GCRY_SOUND=1` |

## Throughput and RSS (`analysis_boehm.txt`, `analysis_tuned.txt`)

| arm | req/s | % Boehm [95% CI] | % tuned [95% CI] | peak RSS × Boehm | faults / 1k | CPU ms / 10k |
|---|---:|---:|---:|---:|---:|---:|
| boehm | 75 754 | 100.0% | 91.3% | 1.00 | 0.5 | 115.4 |
| null | 75 632 | 100.0% [96.5, 103.5] | 91.0% | 0.96 | 0.5 | 117.5 |
| **tuned** | 83 588 | **110.5%** [105.5, 115.6] | 100.0% | **1.29** | 3.4 | 94.8 |
| **sound** | 88 477 | **117.0%** [111.3, 122.6] | 106.5% [100.6, 112.5] | **1.29** | 3.2 | 89.7 |
| sound_cons | 85 293 | 112.8% [108.0, 117.6] | 102.7% [97.4, 108.0] | 1.28 | 3.3 | 92.0 |
| tuned_ec4 | 170 891 | 226.4% | 206.4% | 3.57 | 38.8 | 138.7 |
| sound_ec4 | 84 781 | 112.1% | 101.8% | 3.47 | 41.9 | 255.8 |

EC4 arms are against an EC1 Boehm; the number that matters there is
`sound_ec4` against `tuned_ec4` (`analysis_tuned_ec4.txt`): **50.2%**
[46.7, 53.7] at 0.97× its RSS and 1.8× its CPU per request.

## Pause (medians of the 20 per-trial `/gc-stats` snapshots)

| arm | collections / 15 s | p50 | p99 | max | total |
|---|---:|---:|---:|---:|---:|
| tuned | 589 | **0.78 ms** | 1.58 ms | 2.82 ms | 503 ms |
| sound | 624 | 0.76 ms | 1.20 ms | 2.50 ms | 516 ms |
| sound_cons | 610 | 0.76 ms | 1.29 ms | 2.66 ms | 495 ms |
| tuned_ec4 | 270 | **12.6 ms** | 18.5 ms | 19.2 ms | 3 137 ms |
| sound_ec4 | 151 | **97.1 ms** | 122 ms | 122 ms | 10 595 ms |

`phase_roots_ns` on the last collection: tuned_ec4 12.3 ms, sound_ec4
112 ms — the whole EC4 gap is the root phase, i.e. the two STW lag knobs.

## What it says

1. **On EC1, sound roots are free.** RSS is identical (1.29× all three, and
   all three at the warm-chunk budget), p50 pause identical (0.78 vs 0.76 ms),
   p99 lower, and throughput 106.5% of tuned with the CI touching the null
   band — a small real gain or noise, not a cost. The mechanism is the one
   the 2026-08-06 arithmetic predicted: the heuristics cost per-candidate
   work in the mark (type-id gate, blacklist) and buy nothing on this heap.
2. **On EC4, sound roots cost half the throughput**, and it is entirely the
   pause: p50 12.6 → 97.1 ms, root phase 12 → 112 ms, 270 → 151 collections
   because each one holds the world eight times longer. Same shape as the
   2026-08-09 reading (3.6 → 16.4 ms), larger in absolute terms.
3. **The tuned EC4 pause itself is 12.6 ms with 12.3 ms in roots.** That is
   3.5× the 2026-08-09 EC4 figure (3.60 ms after the low-water fix). Not
   this session's question; recorded as the next thing to attribute
   (`GCRY_ROOT_PHASE_TIMING=1` splits it into fibers/threads/cursors).
4. Against Boehm the EC1 default reads 110.5% here against 105.3% on
   2026-09-06; same host, different day and load (`load1` 1.9–2.7). Inside
   each other's CIs.

## Not measured

The fat app (`acik /api/v1/`) row of the pause table; `GCRY_SCRUB_FIBERS=1`
and `GCRY_DISABLE_BLACKLIST=1` individually.
