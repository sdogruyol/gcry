# The radix wins on Kemal and loses on gc_phases. Both were measured properly.

Date: 2026-09-03 · `simdgc` @ 2c591f2 · WSL2, Ryzen AI 9 HX 375

## The contradiction

| measurement | n | design | result |
|---|---|---|---|
| Kemal (`2026-09-03-simdgc-chunk-radix-ab`) | 32 pairs | paired, interleaved, DiD-corrected, same-n null | `phase_mark` **−6.63%** (p=.016) and **−17.72%** (p=.0001) |
| gc_phases (`2026-09-03-simdgc-gc-phases-radix-ab`) | 32 pairs | 4-arm Latin square, position-balanced, same-n null | `ns_per_alloc` **+1.0 to +1.8%**, `phase_mark` **+2.0 to +4.4%**, 12/12 cells adverse, 5 at p<.05 |
| screening sweep (this file) | 8 pairs | alternating order only | `ns_per_alloc` **−1.1 to −3.2%** |

Neither n=32 batch is dismissible. Both used the amended protocol, both carried
a clean same-n null, and the gc_phases batch was the better-controlled of the
two — it balanced absolute position, which the Kemal batch did not and had to
repair with difference-in-differences afterwards.

## What was ruled out

**Chunk count.** The hypothesis was that at ~466 chunks the sorted index is
~3.7 KB, entirely L1-resident, so a binary search is ~9 L1 hits and beats two
dependent loads through a 512 KiB L1 table. Swept 335 → 788 chunks (heap
41.9 → 98.5 MiB); the penalty is flat: +0.91%, +0.18%, +0.93% on `ns_per_alloc`.
Not a chunk-count effect over this range.

**Pointer locality — untested, not confirmed.** The remaining hypothesis is that
`gc_phases`' ring holds pointers in *allocation order*, so consecutive marked
objects sit in the same chunk, `chunk_containing`'s one-slot cache answers
nearly every lookup, and the binary search the radix replaces barely runs. Kemal
marks a scattered JSON graph where it does. `--shuffle` was added to test
exactly this (Fisher-Yates over the ring, so consecutive entries land in
different chunks).

The screening run does not settle it. At n=8 it reported the radix *winning* in
both modes — −3.23% ordered and −1.06% shuffled — which contradicts the n=32
batch in **sign**, not just magnitude.

## The actual finding

**On this workload the radix's effect is within ±3% and its sign is not stable
across batches.** The n=32 batch's own MDE for `ns_per_alloc` was 1.72–2.35%,
and every measurement above — +1.8%, −3.2%, −1.1% — sits at or under twice that.
Three batches disagreeing in sign at that scale is what an effect at the
resolution floor looks like.

That also disciplines the screening run itself: an 8-pair alternating-order
screen reproduced neither the direction nor the magnitude of a 32-pair
position-balanced one. It was useful for ruling out chunk count (where the
effect was consistent across three sizes) and worthless for adjudicating sign.

## Consequences

1. **Phase 2's "mechanism proven" is retracted, and narrowed to what was
   measured.** What holds: on Kemal, `phase_mark` fell 6.6–17.7% with a fast-hit
   rate of 99.7%, robust to ANCOVA and DiD. What does not hold: any claim that
   the radix is a general improvement. It is not, on the one GC-bound workload
   built to judge it.
2. **The default stays off**, which was already the decision — now for a second,
   better reason than the RSS regression.
3. **`gc_phases` needed the `--shuffle` knob to be honest.** In allocation order
   it is GC-bound but exercises no chunk-*lookup* pressure, so it looked like the
   right instrument for a lookup change and was not. `simdgc-perf-notes.md`
   already recorded graph shape dominating everything else in the mark phase
   (22.8 vs 180 ns/object between chain shapes); that lesson applies to the
   benchmark as much as to the collector.
4. **Do not spend more of this project's budget on it.** The remaining question —
   whether locality decides the sign — needs a position-balanced n=32 across
   ordered/shuffled, roughly 40 minutes, to resolve a ±3% effect on a knob that
   is staying off either way. Phase 3 changes `phase_sweep` by an expected order
   of magnitude and has a genuine throughput claim; that is where the budget
   belongs. This is recorded so the question can be picked up deliberately rather
   than rediscovered.

## Benchmark defects fixed here

Both found by the batch that used it, which is the argument for having an
adversarial reader of one's own instrument:

- `pause_p50_us` / `pause_p99_us` came from the process-cumulative
  `Gcry.pause_stats`, so every survival row after the first was contaminated by
  the earlier ones — overlapping populations presented as independent rows.
  Removed, with the reason recorded in the source.
- `phase_mark_us` is `last_phase_mark_ns`, a **single last-collection sample**,
  giving it roughly double the variance of every other metric. Added
  `pause_per_gc_us` = `pause_total / collections`, averaged over 50+ collections,
  which is the better instrument for mark-side work.
