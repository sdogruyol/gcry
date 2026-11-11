# The incremental finish and the large-cache counters (2026-11-02)

The ROADMAP item "The incremental finishing path never takes or resets the
large-cache counters" (found by reading in `../2026-11-01-large-cache-counters/`).
Confirmed with a test, then fixed. Branch `large-cache-incr-040`, from
`origin/release-0.40.0` (`07b61d28`).

## What the finish did

`run_collection_body` handles the large cache after a major's flushes:

1. it trims the cache to 0 before this cycle's frees join it (recycling only);
2. it swaps `@large_alloc_since_major` and `@large_cache_hits`/`_misses` to
   zero;
3. it keeps up to "since" bytes for `recycle_large_mapping` and sets
   `@large_recycle_budget` to what the cache holds. Without recycling it
   releases the freelist pages, trims to the retain and sets the budget to 0;
4. it moves `@large_cache_retain` by the hit rate.

`collect_a_little`'s finishing slice did only `trim_large_cache(defer: false)`
after its flushes. Under `GCRY_INCREMENTAL=1`, then:

- since, hits and misses added up across every sliced cycle. The next
  stop-the-world major (explicit `GC.collect`, or the fallback when no slice
  can start) read the total.
- the budget kept the value the last stop-the-world major set, and only the
  mutators' spending lowered it. It gates `Heap#allocate`'s trim and
  `large_recycle_keep`.
- the adaptive retain never moved.

Regression 95's control arm runs exactly that code and shows it (below).

## The fix

The large-cache code after the flushes (steps 2–4) moved out of
`run_collection_body` into `Heap#settle_large_cache(major)`
(`@[AlwaysInline]`). Both kinds of major call it: `run_collection_body`
where the code used to be, and the incremental finish after its flushes. The
finish also does step 1 first, in the major's order. The post-stop hook
stages that regression 89 uses now fire from both paths.

Measuring the plain move turned up a second problem. Under
`GCRY_INCREMENTAL=1` it kept each cycle's swept large chunks for recycling,
but nothing ever took them. `recycle_large_mapping` returns early unless
`@barrier_backend.none?`, and with `incremental_auto` (or the nursery)
`arm_page_barrier_after_major` arms a page barrier between every pair of
collections. Revcomp's peak went from 621 to 658 MiB with `large_recycles`
at 0 (table below). So a major's `settle_large_cache` now keeps a cycle's
frees only when no page barrier is armed. The stop chose the barrier before
this point, so the condition sees the barrier the mutators will run under. A
major's cache holds only what that cycle swept, because the major trimmed
it to 0 before its flushes, and only the recycler takes swept chunks. In the
default configuration (no incremental, no nursery)
`arm_page_barrier_after_major` disarms the barrier, so the condition is true
exactly when it was before.

The condition is a major's only:
`@large_recycle && !@release_warm_this_collect && (!major || @barrier_backend.none?)`.
The first version (`0d81deb8`) applied it to minors too, and review caught
the result. Under the nursery a minor runs with the barrier armed, so it
landed in the trim branch and released the program's own `GC.free`d chunks
at every minor. A minor does no trim to 0 first, so its cache holds those
frees, and `alloc_large` takes them back in place under any barrier
(`take_large_free(freed_only: true)`; `ChunkHeader.freed?` is set only by
`GC.free`). `bench/gzip_free_loop.cr` under the nursery
(`-Dgcry_block_headers`, `GCRY_NURSERY=1048576`, 4 985 collections,
3 reps each, `gzip-nursery-runs.txt`):

| tree | unmapped | chunks mapped | peak KiB | loop ms |
|---|---:|---:|---:|---:|
| base `07b61d28` | 1 768 KiB | 37 | 7 780–8 112 | 3 784–3 843 |
| `0d81deb8` (condition on minors too) | **1 350 276 KiB** (the bench's own gate FAILs) | **19 868** | 7 976–8 004 | 3 469–3 496 |
| this branch | 1 768 KiB | 37 | 7 856–8 016 | 3 745–3 783 |

This branch matches base on every count. `0d81deb8`'s loop ran about 8%
faster while mapping a chunk per iteration. That speed is not a reason to
keep it: the program's frees went back to the kernel at every minor, which
is the regression the bench's gate exists for. [INFERENCE] The speed
difference is in the minors' handling of the kept cache. Not chased.

The control is the knob `Heap#inc_finish_large_settle = false` (research
only, like `inc_finish_flush`). It restores the old finish: the trim and
nothing more.

## Regression 95

`process_spec/regression/95_incremental_large_counters_spec.cr`. Six
children, each in its own process. The *counters* and *recycle* windows each
run one whole incremental cycle on their own thread with `incremental_auto`
on, the mprotect barrier, and nothing else allocating large blocks. The
*minor* window needs the nursery (`-Dgcry_block_headers`) and an armed
barrier. It uses the barrier the heap picks (soft-dirty) because the nursery
under the mprotect barrier crashes in a minor after a large `GC.free`, on
base too (reported to Main and handed to NurseryMprotect, regression 99).
A child that cannot reach its window prints the skip marker, as regression
85's do: off Linux, and for *minor* also in the headerless layout or with no
barrier.

Linux x86_64, local, each child run directly:

| window | arm | result |
|---|---|---|
| counters (no recycling): one large allocation, a hit and a miss counted, budget planted at 2^40 | fixed | since 0, hits 0, misses 0, budget 0 |
| | control | `since=942080, hits=1, misses=4, budget=1099511627776`: all four as before the cycle |
| recycle (recycling on): 8 unreachable 276 KiB blocks for the sweep, budget planted | fixed | cache after the flushes ≥ 1 block, cache after ≤ retain (0), budget 0 |
| | control | `budget=1099511627776` (planted value left in place) |
| recycle, the fix *without* the barrier condition (throwaway build) | fixed | **fails**: `Expected 2293760 to be LessOrEqual 0`. The 8 swept blocks were kept for a recycler that cannot run |
| minor (nursery, barrier armed, recycling on): a 308 KiB block `GC.free`d, then a minor | fixed | cache 319 488 before and after the minor |
| | control (a major instead of the minor) | `the major trimmed the cache: 319488 -> 0`: the instrument sees a drop |
| minor, at `0d81deb8` (throwaway build) | fixed | **fails**: `Expected: 319488`. The minor trimmed the program's free |

## Incremental workloads, before and after

Local Linux x86_64 (12-vCPU QEMU guest), crystal-metric (the nine keep-rule
benches) built from `07b61d28` (base) and from this branch (var), with
`bench/runner_ab/gc_counters.cr` prepended (`build.sh`). Every run used
`GCRY_INCREMENTAL=1`, 3 reps per arm, interleaved, each run under the shared
lock (`meas.sh`). Peak is `/usr/bin/time %M`. Raw lines are in
`incremental-gated-runs.txt` (final fix) and `incremental-ungated-runs.txt`
(the move without the barrier condition, a separate session with the same base).

| bench | peak MiB base | var (final) | var (no barrier condition) | collections base / var | unmapped MiB base / var | large_recycles |
|---|---:|---:|---:|---:|---:|---:|
| Primes | 593 | 593 | 592 | 16 / 16 | 663 / 663 | 0 / 0 |
| JsonParsePure | 546 | 546 | 546 | 29 / 29 | 429 / 430 | 0 / 0 |
| Binarytrees | 27 | 27 | 27 | 333 / 333 | 22 / 22 | 0 / 0 |
| JsonGenerate | 940 | 940 | 940 | 32 / 32 | 591 / 591 | 0 / 0 |
| JsonParseSerializable | 535 | 535 | 533 | 26 / 26 | 738 / 738 | 0 / 0 |
| JsonParsePull | 535 | 535 | 534 | 24 / 24 | 672 / 672 | 0 / 0 |
| Revcomp | 621 | 621 | **658** | 34 / 34 | 1 032 / 1 032 | 0 / 0 |
| RegexDna | 303 | 303 | 303 | 23 / 23 | 458 / 458 | 0 / 0 |
| Knuckeotide | 45 | 45 | 45 | 93 / 93 | 77 / 77 | 0 / 0 |

`large_recycles` is 0 in both arms under `GCRY_INCREMENTAL=1`: the barrier
blocks recycling either way. In default mode the same binaries recycle 8
times on Revcomp and twice on JsonGenerate. The hit and miss counts at exit
cannot be compared across arms: var zeroes them at every sliced cycle, base
only at a stop-the-world major. The collector does the same work in both
arms. Timed sections overlap rep for rep (for example Primes base 2.37–2.51 s,
var 2.42–2.58 s; JsonGenerate base 0.59–0.67 s, var 0.60–0.70 s). With 3 reps
on a shared host they are not a perf measurement.

Under `GCRY_INCREMENTAL=1` the visible change is to the counters and the
budget. Peak RSS and the cache's behaviour match base. The rejected variant
cost Revcomp 37 MiB.

## Keep rule (default path)

The default path's machine code changes: the code moved into
`settle_large_cache`, the adaptive retain now runs before
`@last_phase_flush_ns` is written, and the recycle condition gains
`(!major || @barrier_backend.none?)`.

Perf A/B [41296291944](https://github.com/sdogruyol/gcry/actions/runs/41296291944),
`6f8e6a77` (the final source) against `07b61d28`, all five runners, nine
benches, 15 reps, Boehm arm, pads `p16 p64 bp16 bp64`. All five runners
green. `keep.txt` holds `../2026-11-01-0.40-keep-rule/keep.py`'s output, and
`raw/` the summaries. Rows slower beyond their spread, timed-section medians (s):

| runner | bench | var vs base | var / p16 / p64 | base / bp16 / bp64 | |
|---|---|---|---|---|---|
| ubuntu-latest | JsonGenerate | time +3.0% [+2.6, +3.3], wall +1.0% | 1.384 / 1.431 / 1.471 | 1.344 / 1.384 / 1.437 | pads |
| ubuntu-latest | Revcomp | wall +0.4% [+0.2, +0.7] | 1.541 / 1.579 / 1.544 | 1.533 / 1.531 / 1.582 | pads |
| ubuntu-latest | Knuckeotide | time +1.4% [+0.9, +2.2], wall +1.4% | 1.348 / 1.336 / 1.343 | 1.326 / 1.342 / 1.345 | pads |
| ubuntu-24.04-arm | JsonParseSerializable | time +0.6% [+0.2, +0.9], wall +0.8% | 0.653 / 0.647 / 0.652 | 0.649 / 0.644 / 0.645 | pads |
| ubuntu-24.04-arm | JsonParsePull | wall +0.5% [+0.0, +0.8] | 0.641 / 0.636 / 0.638 | 0.640 / 0.633 / 0.633 | pads |
| ubuntu-24.04-arm | Revcomp | time +0.5% [+0.2, +1.0], wall +0.1% | 1.251 / 1.239 / 1.243 | 1.243 / 1.242 / 1.237 | pads |

Each flagged row has a var-code median inside or below the base-code range,
so each counts as placement. `macos-latest`, `macos-15-intel` and
`windows-latest`: no row slower beyond its spread. Peak: the only rises
beyond spread are macos-15-intel Binarytrees and macos-latest JsonGenerate,
each +0.0% [+0.0, +0.1]. Every row is within 1.1× Boehm except Knuckeotide,
the documented exception (var 1.16–1.56×, base 1.16–1.53×).

The run on `0d81deb8`, before the minor fix, read the same:
[41289615508](https://github.com/sdogruyol/gcry/actions/runs/41289615508).
Every flagged row there was excused by the pads too (ubuntu-latest Primes
+2.8%, JsonGenerate +2.7%, Revcomp wall +0.4%; arm64 Revcomp +1.0%;
macos-latest RegexDna wall +1.1%; macos-15-intel JsonParsePure +4.3%).

**Verdict:** the change stays in. Every flagged row is excused by the
same-session pads, and peak is unchanged.

## Checks

Local, each step under the shared lock, on `6f8e6a77` (the final source).

| check | result |
|---|---|
| `verify.sh`: format check | clean |
| `make lint` | 248 inspected, 0 failures |
| `crystal spec -Dgc_none spec/all_specs.cr` | 303 examples, 0 failures |
| `… -Dgcry_block_headers spec/all_specs.cr` | 325 examples, 0 failures |
| `GCRY_DEBUG_INVARIANTS=1 … spec/all_specs.cr` | 303 examples, 0 failures |
| `crystal spec -Dgc_none process_spec` | 342 examples, 0 failures, 2 pending |
| `… -Dgcry_block_headers process_spec` | 343 examples, 2 suite runs of 11 had 1 failure each, see below |
| `GCRY_BITMAP_ALLOC=0 … -Dgcry_block_headers process_spec` | 343 examples, 0 failures, 2 pending |
| `process_spec` on Crystal 1.22.2 | 342 examples, 0 failures, 2 pending |
| `make windows-typecheck`, `make darwin-typecheck` | clean |
| `make alloc-entry-frame` | 5 examples, 0 failures |

The block-headers `process_spec` runs: 9 of 11 green. One failure was in
`verify.sh`, which keeps only the last lines, so which example failed is
not known. The other was regression 61's second example, at its positive
control (`control[0].value.should be_nil`: the WeakRef target was still
alive after three collections). That example is a conservative-retention
check: it needs a target that no stale word roots. Run alone, each tree
built once, 61 failed 0 of 40 on base and 0 of 40 on this branch. Base's
suite ran green 4 of 4. [INFERENCE] The rate is too low to pin on this
change from these counts, and nothing in it touches small objects or weak
links. The likeliest link is that the nursery's majors now trim swept large
chunks, which moves where later blocks land, and the positive control is
sensitive to layout.
