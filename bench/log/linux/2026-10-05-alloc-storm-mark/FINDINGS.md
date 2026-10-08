# Allocation storms: where Primes and JsonParsePure lose to Boehm, and five fixes

Host: QEMU x86-64 guest, 12 vCPUs, Crystal 1.21.0, crystal-metric `--release`,
process-fresh. `perf` is not permitted (`perf_event_paranoid=4`); profiles are
the SIGPROF sampler of `../2026-10-03-monitor-wait-spin/sampler.c`, phase
splits are `GCRY_TRACE=1` and an instrumented copy of `metric.cr` that prints
in-window `getrusage` and `Gcry.metrics` deltas around `run`. A/B runs are
`ab.py` here: every arm and bench a fresh process, arm order shuffled per
(trial, bench), medians with min/max. Base is `adc52ba`.

## Where the time goes (base, default `min(2, CPUs − 1)` = 2 workers)

| | Boehm (12 markers) | gcry |
|---|---|---|
| Primes timed window | 0.62 s, 15 GCs, ~70 ms GC | 1.03 s, 10 GCs in window, **434 ms pause** (all mark) |
| Primes, collections off | 0.56 s | 0.58 s (+5%) |
| JsonParsePure timed window | 0.34 s | 0.55 s, 7 GCs, **191 ms pause** |
| JsonParsePure, collections off | 0.31 s | 0.37 s (+20%; +30k page faults) |
| Σ mark, one marker, whole process | Primes 368 ms, JPP 387 ms | Primes 858 ms, JPP 820 ms |

- The gap is the mark. Mutator time is within 5% on Primes. Per thread
  gcry marks at ~2.3× Boehm's cost, and it used 2 threads where Boehm uses
  12.
- Sweep, roots, STW and flush are all under 3% of the window.
- Mark profile (serial): the word loads of scanned objects (dependent
  misses), `mark_impl_unlocked` (~23% of all samples), and a second radix
  and chunk-header lookup per scanned object in `scan_object` (~5%).
- With more workers the helpers joined each mark late: between collections
  they sleep in `nanosleep` naps of up to 5 ms. Helpers that spin instead
  cut Σ mark 10–15% (JPP, Primes, 4 workers) and 15–50% on
  JsonParseSerializable, at 2× the CPU.
- JsonGenerate's mark at 4–6 workers did not scale: one worker scanned the
  70+ MB `Array(Coordinate)` buffer whole while the others spun
  (`mark_worker_loop` 14.7% of samples at 6 workers).
- JsonParsePure's mutator gap is page faults: the run maps fresh size-class
  chunks (the pre-run `GC.collect` released the setup's memory, by design)
  and faults them in a page at a time.

## Changes, each measured

1. **Size class in the mark-stack entry** (`collect_mark.cr`). The trace's
   pushes put `class + 1` in the entry's top byte, so `scan_object` reads
   payload and length without resolving the chunk again. Serial Σ mark,
   alternating runs: Primes 870 → 799 ms (−8.5%), JPP 823 → 760 ms (−7.5%).
2. **Large payloads split under parallel mark** (`scan_large_from`):
   64 KiB at a time, the rest pushed to the shared stack as a tagged rest
   entry. JsonGenerate Σ mark at 4 workers 471 → 359 ms, JPP 265 → 247 ms;
   no change at 2 workers.
3. **Radix hit inline in `find_block_with_chunk`** under the stop: serial
   Σ mark −3% (Primes 805 → 776, JPP 763 → 744); within noise at 2 workers.
4. **Idle helpers wait on a futex the master wakes** (Linux;
   `wait_for_mark_epoch` / `wake_mark_helpers`, same timeout as the old
   nap). Σ mark at 4 workers JPP 265 → 218 ms (−18%), Primes −4%; wall
   JPP 0.49 → 0.475, Primes 0.86 → 0.84; CPU unchanged.
5. **Default workers scale with CPUs**: `min(2, CPUs − 1)` up to 7 CPUs
   (unchanged on the 3- and 4-CPU runners the 2026-10-05 default was cut
   on), then `CPUs / 4 + 1`, at most 8 (4 here). With 1–4 in place
   (`ab-fx-pm`, 7 trials):

   | workers | Primes | JPP | JPS | JG CPU |
   |---|---|---|---|---|
   | 2 | 0.988 s | 0.527 s | 0.306 s | 2.53 s |
   | 3 | 0.881 | 0.488 | 0.305 | 2.66 |
   | 4 | 0.828 | 0.470 | 0.308 | 2.84 |
   | 6 | 0.806 | 0.452 | 0.306 | 3.12 |

   Six gains 2–3 more points for 10% more CPU again; base at 8 workers was
   no faster than 6 (`ab-pm-sweep` for base).
6. **Fresh size-class chunks populated in one call once the heap passes
   32 MiB** (`MADV_POPULATE_WRITE`, Linux 5.14+, `map_chunk`). Same fault
   count, about half the system time (`ab-populate`, 5 trials). Shipped as
   arm `p3` (floor, size classes only): JPP −5.6%, Primes −1.1%, the rest
   within noise, RSS unchanged. `p1` (every chunk) read JPP −5.1%, Primes
   −3.0%, but cost Binarytrees +14% RSS (22 → 25 MiB), hence the floor;
   populating large objects too (`p2`) cost JsonParseSerializable +15% and
   JsonGenerate +11% RSS, so they are left out.

## Result (`ab-final`, 7 trials; speed = Boehm s / gcry s)

| bench | Boehm | base | new | new, 2 workers | RSS × Boehm base → new |
|---|---|---|---|---|---|
| Primes | 0.606 s | 1.003 (60.4%) | **0.784 (77.3%)** | 0.927 (65.4%) | 0.90 → 0.90 |
| JsonParsePure | 0.346 | 0.556 (62.2%) | **0.437 (79.2%)** | 0.495 (69.9%) | 0.79 → 0.79 |
| JsonParseSerializable | 0.267 | 0.301 (88.7%) | 0.305 (87.5%) | 0.308 | 0.77 → 0.76 |
| Binarytrees | 0.512 | 0.627 (81.7%) | 0.611 (83.8%) | 0.615 | 0.43 → 0.43 |
| JsonGenerate | 0.634 | 0.597 (106%) | 0.584 (109%) | 0.587 | 0.74 → 0.73 |
| RegexDna | 1.713 | 1.725 (99.3%) | 1.740 (98.4%) | 1.752 | 0.53 → 0.53 |

Spreads (min–max) are in `ab-final/summary.txt`; every new Primes/JPP run
is faster than every base run. CPU (user+sys, whole process): Primes
1.47 → 1.50 s, JPP 1.58 → 1.62, JPS 1.13 → 1.21, JG 2.51 → 2.72.

JsonParseSerializable (+0.8–2%) and JsonGenerate (±4%) are not GC effects.
Their timed windows run no mark (JG: 0 collections; JPS: 3 with <1 ms of
pause), with identical fault and allocation counts, and they move by the same
amount between builds that differ only in GC code placement: JPS −1.0% to
+2.0%, JG +0.5% to +3.9% across seven such builds, including two that differ
from each other by one `@[NoInline]` (`ab-jps-layout`, `ab-jg-layout`). The
hot JSON functions shift between 0/16/32/48 mod 64 across those builds.

Small heaps (`small-heap.txt`, 9 interleaved reps, library built from
`adc52ba` vs this tree): `gc_phases` 200k live mark per GC −12%, ns/alloc
−8.5%; 20k live fanout 6 mark −12%; `alloc_ns` 48 B −1.1%; `json_churn
300000` wall −1.7%, p99 pause −1%, RSS −1.6%. All below the parallel floor,
so these are change 1 and 3 only.

## Tried and dropped

- Plain (non-atomic) mark-bit OR during a serial stopped-world mark: Σ mark
  unchanged (Primes 790 vs 793 ms, JPP 762 vs 767).
- Not releasing on the pre-run explicit `GC.collect`
  (`collect(release_warm: false)`): JPS faults 35.8k → 35.2k, JPP −9k, wall
  unchanged. Freed memory is in large chunks, which size classes cannot
  reuse; Boehm's run reuses the setup's pages (JPS 9.9k faults vs 35.8k).
- Raising worker counts without 2 and 4: helpers spin idle on narrow graphs
  (JsonGenerate) and join late; both are what changes 2 and 4 fix.

## Remaining gap

- Primes 77%, JsonParsePure 79%. Mark is still ~2.1× Boehm per thread and
  uses 4 threads to Boehm's 12; six workers would add 2–3 points each.
- JsonParseSerializable (88%) and part of JsonParsePure are page faults:
  gcry does not reuse a freed large object's pages for size-class chunks
  (separate mappings), Boehm does. A shared page arena is the fix.
- Binarytrees (84%): 259 collections against Boehm's 85 under the 8 MiB
  threshold floor — the RSS-budget decision, not mark speed.

## Gates

`crystal spec` (292), `crystal spec -Dgc_none process_spec` (78, one new),
`… -Dgcry_block_headers process_spec` (78), `ci/std-spec.sh --chunks 4`
(4 chunks, 0 failures), `make parallel-mark-stress mark-audit
parallel-mark-process interior-only-buffer finalizer-complex
parallel-mark-termination`: green. `parallel-mark-termination` failed at
`adc52ba` as well (its 4 MiB graph sits under the 32 MiB serial floor, so
`runs=0`); the harness now sets `parallel_mark_min_live = 0`, and its red arm
damages the graph again. Benchmark outputs: identical result lines for
Boehm, base and new on all six rows.
