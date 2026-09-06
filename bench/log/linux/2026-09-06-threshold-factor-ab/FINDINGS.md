# `GCRY_THRESHOLD_FACTOR` against RSS, on both workloads

Tree `fd8835a` (the bitmap allocator as the process default). The question
from `../2026-09-06-bitmap-default-ab/`: the bitmap default sits at 1.30×
Boehm's peak RSS on Kemal, and the warm-chunk budget follows live ×
`GCRY_THRESHOLD_FACTOR` capped by the threshold — does cutting the factor
buy the RSS without costing throughput?

## Kemal `/json` — `kemal_ab.py`, 20 rotated rounds, null control

`arms.json`, `manifest.json`, `trials.jsonl`, `analysis_*.txt` beside this
file. Null: 98.0% [93.8, 102.3].

| arm | ratio vs Boehm [95% CI] | peak RSS × | faults / 1k | CPU ms / 10k | peak KiB (median) |
|---|---:|---:|---:|---:|---:|
| factor 100 (default) | 107.4% [100.3, 114.6] | 1.31 | 2.6 | 76.5 | 37 458 |
| factor 75 | 98.6% [93.6, 103.6] | 1.13 | 2.3 | 83.0 | 32 318 |
| factor 50 | 105.1% [97.6, 112.5] | **0.95** | 1.1 | 78.9 | 27 316 |

Throughput: the three arms are inside the null's band of each other
(against factor 100: 75 at 92.4% [88.6, 96.2], 50 at 98.3% [92.6, 104.0]).
RSS tracks the factor linearly. On Kemal the live set is ~10 MB, so
live × 50% = 5 MB is below the 8 MiB threshold floor: the *threshold* does
not move, only the warm budget does, and factor 50 lands exactly on the
product bar (≥95% @ ≤1.0×).

## acikturkiye `/api/v1/` — `acik_ab.sh`, 8 paired order-rotated trials

Same box, back to back (`acik/f100.txt`, `acik/f50.txt`,
`acik/freelist.txt`), host load 2 → 10 across the three runs; the paired
ratio absorbs most of that, the spread says how much it did not.

| arm | median thr ratio | spread | median RSS × | collections / trial |
|---|---:|---:|---:|---:|
| bitmap, factor 100 (the new default) | **90.8%** | 84.3–92.9 | 1.55 | 335–420 |
| bitmap, factor 50 | 78.8% | 74.2–89.1 | 1.32 | 560–770 |
| freelist (`GCRY_BITMAP_ALLOC=0`, the old default) | 80.7% | 72.4–95.0 | 1.47 | 234–307 |

Here the live set is ~16 MB post-GC, so factor 50 halves the *threshold*
too (16 → 8 MiB): collections per trial go up 1.7×, and throughput drops
**12 pp** — the same major-cycling regression a fixed 16 MiB produced on
this app in August (`gc_override.cr`, "regressed acikturkiye by ~20pp").
The RSS it buys (1.55 → 1.32×) is less than Kemal's, because the fat app's
RSS is its live set and its fragmentation (heap 88 MB against Boehm's
55 MB RSS), not the warm budget.

The new default is also the best arm for acikturkiye's throughput: 90.8%
against the freelist's 80.7%, at 1.55× vs 1.47× RSS.

## Decision

**Factor stays at 100.** The warm budget and the threshold share one knob,
and the number that fixes Kemal's RSS breaks the fat app's throughput. Two
things would let RSS move without the threshold:

- a separate percentage for the warm budget (`GCRY_WARM_RETAIN_FACTOR`),
  so Kemal can hold 5 MB warm while acikturkiye keeps its 16 MiB
  threshold — the knob split is small, the measurement is the cost;
- the fat app's RSS above Boehm is live set + fragmentation, which no
  retention policy touches; that is the open ROADMAP line (finalizer
  retention, freelist residual), not this knob.

Neither is a 0.24.0 blocker: the new default improves throughput on both
workloads against what shipped, and the RSS it adds on the fat app is 5%.
