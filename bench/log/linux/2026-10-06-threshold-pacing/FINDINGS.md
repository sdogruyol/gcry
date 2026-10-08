# Pacing the adaptive threshold by collection time

Host: the 12-vCPU QEMU guest of `../2026-10-05-alloc-storm-mark/`, Crystal
1.21.0, crystal-metric `--release`, process-fresh. Every build and run under
`taskset -c 8-11`, so gcry counts 4 CPUs (2 mark workers) and every arm,
Boehm included, sees the same 4. Harness: `../2026-10-05-alloc-storm-mark/ab.py`
(arm order shuffled per trial and bench; in-run wall, whole-process CPU and
peak RSS). Base is `readiness` at `7d2c7b3`. Three other agents were
benchmarking on CPUs 0-7 throughout, so absolute times drift between runs;
compare arms within one table.

## The question

Binarytrees ran 259 majors to Boehm's 85, Primes spent 430 ms of a 1 s run in
pause, and gcry's peak RSS was 0.43-0.90× Boehm's. Raising the cap
(`GCRY_THRESHOLD_MAX=256 MiB`, `../2026-10-05-threshold-cap-local/`) bought
Primes 13 points and cost JsonParseSerializable 12-16. Is there a trigger that
collects less often where collection is the cost and leaves the rest alone?

## What the schedule was

`collect_end` now carries the threshold, the size-class live bytes, the bytes
the mark scanned and the pace (`trace.cr`), which is how these were read:

- **Binarytrees** is not a large live set. `long_lived_tree` is never read
  again and the trace reads 0 MiB live through the shallow iterations; ~200
  majors run at < 1 MiB live in ~60 us each. The cost is the last phase,
  1-5 MiB live, 0.8-2.4 ms a major, every 8 MiB (the floor). Boehm: 85
  collections, the heap at 43 MiB from the stretch tree onward. Boehm's heap
  keeps its high-water size and it collects when that is full, so the
  stretch tree buys every later phase ~40 MiB between collections.
- **Primes** grows to ~310 MiB live, all of it scanned; the threshold sits on
  the cap (64 MiB, then a third of the scanned bytes). 13 majors, 430 ms.
- **JsonParseSerializable**'s timed run has three cheap majors (< 1 ms of
  pause); what made the cap raise expensive there was fresh memory, not
  marking.

## Tried

`explore-factor/` (3 trials): `GCRY_THRESHOLD_FACTOR=300` alone took Primes
1.125 → 0.858 s and Binarytrees 0.688 → 0.598 with every peak under Boehm's,
and JsonParseSerializable did not move — the factor scales the cap through
the *scanned* bytes, which an atomic live set does not have, where the cap
raise scaled it for every heap. But a factor applies to every program: Kemal
`/json` already sits at 1.42× Boehm's peak on this host (`kemal-final-json/`,
pacing off), and `docs/PERF.md` measured that peak linear in the factor.

So the factor should move only while collection is what the program is doing.
**Pacing** (`Heap#adapt_after_sweep`): after each automatic major, the pace is
the threshold that would hold this cycle's time to 10% of the mutator time
since the previous one (allocated bytes ÷ mutator time × cycle time ÷ 0.1),
over the unpaced threshold, clamped to 100-300%; it scales live × factor and
the cap. The allocated bytes and the mutator time both scale with the
threshold, so the measured rate does not and the pace does not oscillate.

Variants (`ab-p1/` 3 trials, `ab-sweep/` 5 trials; wall s, peak RSS MiB):

| arm | Primes | JsonParsePure | JsonParseSerializable | Binarytrees |
|---|---|---|---|---|
| Boehm (sweep) | 0.829 / 659 | 0.405 / 690 | 0.309 / 533 | 0.641 / 51 |
| base | 1.180 / 595 | 0.574 / 543 | 0.332 / 437 | 0.684 / 22 |
| max 200% | 0.836 / 611 | 0.499 / 569 | 0.344 / 475 | 0.622 / 30 |
| max 250% | 0.893 / 608 | 0.466 / 558 | 0.337 / 508 | 0.637 / 34 |
| **max 300%** | **0.812 / 617** | **0.421 / 576** | 0.333 / **549** | **0.622 / 38** |
| max 300%, target 20% | 0.895 / 613 | 0.438 / 572 | 0.344 / 549 | 0.639 / 38 |
| max 400%, target 20% | 0.787 / 618 | 0.440 / 579 | 0.335 / 549 | 0.632 / 47 |

300% at 10% gains the most on JsonParsePure and Binarytrees; 200% gives
JsonParsePure half of it, a 20% target gives back a quarter of Primes'.
`ab-p1/` had max 400% at 10% worse than 300% on JsonParsePure (0.405 vs 0.378)
and RegexDna (1.862 vs 1.795), with Binarytrees' peak at 47 MiB.

**What did not work as first written: keeping the pace across `GC.collect`.**
JsonParseSerializable's peak went 437 → 549-565 MiB (+26-29%; Boehm 533-573
across runs) with its wall unchanged. Its setup — building and serialising
800k coordinates — is collection-bound, so the pace reached 300%; the
benchmark's pre-run `GC.collect` kept it, and the timed run went its whole
0.3 s on one 192 MiB threshold without collecting what the setup left behind
(trace: the run had one major instead of base's three). A releasing
collection (`GC.collect`, the idle collector, the emergency one) asks for the
footprint back, as it already does of the warm budget, so it now resets the
pace to 100%; the next automatic major measures afresh. JsonParseSerializable's
run is then base's again: three majors at a 64 MiB threshold. Its peak is
477 MiB against base's 437; the setup still runs paced.

## Result (`ab-final/`, 7 trials; speed = Boehm s / gcry s)

| bench | Boehm | base | new | speed base → new | peak RSS × Boehm base → new |
|---|---|---|---|---|---|
| Primes | 0.715 s, 659 MiB | 1.017 (0.939-1.072), 595 | **0.758** (0.701-0.776), 617 | 70.3% → **94.3%** | 0.90 → 0.94 |
| JsonParsePure | 0.366, 686 | 0.497 (0.488-0.551), 543 | **0.388** (0.380-0.454), 575 | 73.6% → **94.3%** | 0.79 → 0.84 |
| JsonParseSerializable | 0.279, 573 | 0.295 (0.290-0.304), 437 | 0.299 (0.289-0.335), 477 | 94.6% → 93.3% | 0.76 → 0.83 |
| JsonGenerate | 0.639, 1303 | 0.604 (0.597-0.637), 856 | 0.622 (0.607-0.629), 857 | 105.8% → 102.7% | 0.66 → 0.66 |
| Binarytrees | 0.539, 51 | 0.617 (0.612-0.631), 22 | **0.564** (0.534-0.580), 39 | 87.4% → **95.6%** | 0.43 → 0.76 |
| RegexDna | 1.745, 525 | 1.740 (1.715-1.784), 272 | 1.761 (1.719-1.815), 272 | 100.3% → 99.1% | 0.52 → 0.52 |
| Revcomp | 0.531, 899 | 0.588 (0.578-0.632), 560 | 0.631 (0.627-0.660), 560 | 90.3% → 84.2% | 0.62 → 0.62 |

Every new Primes, JsonParsePure and Binarytrees run is faster than every
base run. CPU (user+sys, whole process) falls with the majors: Primes
1.46 → 0.91 s, JsonParsePure 1.47 → 1.18, JsonGenerate 2.55 → 2.09,
Binarytrees 0.62 → 0.56. Majors and pause per process are in `counts.txt`
(Primes 13 → 8 majors, 430 → 124 ms; JsonGenerate 27 → 14, 563 → 321 ms).
Benchmark result lines are identical across Boehm, base and new on all seven
rows (several rows print `err` for all three when run one at a time — the
expected values assume the full suite's order — which is not a GC effect).

**Revcomp is not the policy.** Same binary, pacing on and off
(`ab-revcomp-layout/`, 7 trials): 0.642 vs 0.638 s; a second build without the
trace fields: 0.612 vs 0.609; an earlier pacing build (`p1`): 0.603. Against
base's 0.587 the builds differ by +2.4% to +9.4% whatever the policy. Revcomp
runs 2.6 ms of pause in the whole process and its run is `IO::Memory`
growth and string copies; the alloc-storm findings saw the same build-to-build
movement on JsonParseSerializable and JsonGenerate. JsonGenerate's run has no
collection at all; `ab-revcomp/` has it at +0.8% (new) and +1.3% (pacing off).

**Kemal `/json`** (`kemal-final-json/`, server on CPUs 8-10, `wrk -t1 -c50
-d10` on 11, 7 trials): pacing off 44 217 req/s, on 43 242 (spreads
41.5-44.9k and 41.5-47.3k), peak RSS 22.3 vs 22.2 MiB, post-`/gc-collect`
13.9 vs 13.8. `/` (5 trials): 124 098 vs 127 281 req/s, peak 21.7 both. Its
collections cost under a tenth of its mutator time, so the pace stays at
100%. (Boehm on this host: 15.6 MiB; the 1.42× is the existing warm budget,
unchanged here.)

## Gates

All under `taskset -c 8-11` on `4e1135e`: `crystal tool format --check src spec
process_spec bench`, `make lint` (0 failures), `ci/knob-doc-check.sh` (217
knobs), `crystal spec` (295), `crystal spec -Dgc_none process_spec` (78),
`… -Dgcry_block_headers process_spec` (78), `GCRY_BITMAP_ALLOC=0 …` (78),
`make parallel-mark-stress mark-audit parallel-mark-termination
thread-death-window interior-only-buffer unaligned-only-buffer
finalizer-complex idle-rss-after-burst idle-release rss-leak pause-budget`,
`make darwin-typecheck windows-typecheck`: green, every red arm red.

## Risks

- The pace is wall-clock. A preempted or page-faulting cycle reads as an
  expensive one and can pace one threshold up; the clamp bounds it at 3× and
  the next cycle measures again. Revcomp's trace shows single 300% spikes when
  two collections land 15 ms apart; its peak RSS did not move.
- Peak RSS rises wherever pacing works — Binarytrees 22 → 39 MiB, up to
  0.94× Boehm on Primes. A collection-bound phase now spends memory as
  Boehm's heap does; a cheap-collection program does not.
- Measured on Linux x86-64 at 4 CPUs only. Darwin's floor is 16 MiB and its
  mark speed differs; the 10% / 300% pair was not cut there.
