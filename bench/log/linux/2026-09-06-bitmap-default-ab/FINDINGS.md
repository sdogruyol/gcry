# Should `GCRY_BITMAP_ALLOC=1` be the default? The five-arm paired run

Tree `8421f7b` (v0.23.0 + the six review carry-overs, #35, the unaligned
root default, and the incremental note). `bench/performance/kemal_ab.py`,
Kemal `/json`, 20 rotated rounds × 5 arms, 15 s per trial after warmup,
identical-binary null control. `arms.json`, `manifest.json`, `trials.jsonl`
and both analyses are beside this file. Host: Ryzen AI 9 465 (12c/24t),
Linux 7.2.2, load1 2.8–2.9 throughout (a browser was open; the null arm is
what says how much that cost).

## Result

Against Boehm (`analysis_boehm.txt`):

| arm | req/s | ratio [95% CI] | t | peak RSS × | faults / 1k req | CPU ms / 10k |
|---|---:|---:|---:|---:|---:|---:|
| boehm | 101 268 | 100.0% | | 1.00 | 0.4 | 87.8 |
| null (same binary) | 98 265 | 97.5% [93.0, 102.0] | −1.17 | 1.00 | 0.4 | 89.9 |
| **header** (the shipping default) | 75 455 | **74.9%** [70.9, 78.9] | −13.15 | **1.87** | **1 671** | 112.9 |
| **bitmap** (`GCRY_BITMAP_ALLOC=1`, header layout) | 106 453 | **105.3%** [99.2, 111.3] | 1.83 | 1.30 | 2.7 | 74.6 |
| headerless (`-Dgcry_headerless`) | 113 552 | **112.6%** [106.6, 118.6] | 4.43 | 1.07 | 1.1 | 69.0 |

Against the shipping default (`analysis_header.txt`): bitmap is
**141.9% [132.1, 151.6]** of it at **0.69× its peak RSS**; headerless
**151.7% [142.0, 161.4]** at 0.57×.

RSS, by phase (medians, KiB):

| arm | peak (HWM) | post-GC | wrk p99 µs |
|---|---:|---:|---:|
| boehm | 29 252 | 29 252 | 2 600 |
| header | 54 102 | 16 888 | 6 380 |
| bitmap | 37 524 | 37 540 | 2 360 |
| headerless | 31 190 | 31 210 | 2 210 |

## What it says

1. **The shipping default loses on every column.** 75% of Boehm's
   throughput, 1.87× its peak RSS, 1 671 minor faults per 1 000 requests
   (Boehm: 0.4), 29% more CPU per request, and a p99 2.5× worse. The header
   allocator's only good number is post-GC RSS (16.9 MB), and that is the
   *cause* of the rest: it releases every emptied chunk and pays a fresh
   page for every 8 KiB response buffer the next cycle hands out.
2. **The bitmap allocator on the same header layout is at Boehm parity on
   throughput** (105.3%, CI straddles 100) with 15% less CPU per request,
   Boehm's fault count, and a better p99 — at 1.30× Boehm's peak RSS, which
   is 0.69× the *current default's* peak. The RSS is the warm-chunk budget:
   37.5 MB flat (post-GC = peak), where the header build spikes to 54 MB and
   collapses to 17 MB.
3. **Headerless is the best arm on every column but RSS, and RSS is 1.07×.**
   It is a compile flag, not a knob, so it cannot be the default of a shard.
4. The null control (97.5% [93.0, 102.0]) puts the box's noise at ±4.5 pp on
   a paired ratio, so the bitmap–header gap (+42 pp) and the bitmap–Boehm
   gap (+5 pp, not significant) are read correctly.

## Against the product bar

ROADMAP: `/json ≥95% @ ≤1.0× RSS`. Bitmap passes the first half at parity and
misses the second at 1.30×. But the bar was written against the *header*
default, which is at 74.9% @ 1.87× peak — the bar is already failed harder by
what ships. Making bitmap the default is a strict improvement on every axis
against what ships today; the remaining RSS gap to Boehm is the warm-chunk
budget (`GCRY_EMPTY_CHUNK_WARM_RETAIN` follows live × `GCRY_THRESHOLD_FACTOR`,
capped by the threshold), a policy knob rather than a representation cost —
headerless with the same policy sits at 1.07×.

## Recommendation

Flip `GCRY_BITMAP_ALLOC` to default-on in 0.24.0, keep `GCRY_BITMAP_ALLOC=0`
as the escape, and cut the warm budget against RSS in the same release
(`GCRY_THRESHOLD_FACTOR` 100 → 50–75 is the first thing to measure: RSS
tracks it linearly, throughput should not). Prerequisites before the flip:

- every gate in the Makefile under `GCRY_BITMAP_ALLOC=1` (the spec suites
  already run under it in CI; the gates do not, `tasks/todo.md` has the
  item);
- the Darwin runner's spec + process-spec under the knob;
- acikturkiye on the knob for a day, since Kemal `/json` is not the fat app.

## Not measured here

Darwin (no host). EC4 (`EC_PARALLELISM>1` keeps its fixed 64 MiB and is not
adaptive; the same five arms should be run under it before the flip). Latency
under the bitmap arm is a bonus, not a claim: one workload, one box.
