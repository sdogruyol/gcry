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
at 0 (table below). So `settle_large_cache` now keeps a cycle's frees only
when `@large_recycle && !@release_warm_this_collect && @barrier_backend.none?`.
The stop chose the barrier before this point, so the condition sees the
barrier the mutators will run under. In the default configuration (no
incremental, no nursery) `arm_page_barrier_after_major` disarms the barrier,
so the condition is true exactly when it was before.

The control is the knob `Heap#inc_finish_large_settle = false` (research
only, like `inc_finish_flush`). It restores the old finish: the trim and
nothing more.

## Regression 95

`process_spec/regression/95_incremental_large_counters_spec.cr`. Four
children, each in its own process. Each runs one whole incremental cycle on
its own thread with `incremental_auto` on, the mprotect barrier, and nothing
else allocating large blocks. Off Linux a child prints the skip marker, as
regression 85 does.

Linux x86_64, local, each child run directly:

| window | arm | result |
|---|---|---|
| counters (no recycling): one large allocation, a hit and a miss counted, budget planted at 2^40 | fixed | since 0, hits 0, misses 0, budget 0 |
| | control | `since=942080, hits=1, misses=4, budget=1099511627776`: all four as before the cycle |
| recycle (recycling on): 8 unreachable 276 KiB blocks for the sweep, budget planted | fixed | cache after the flushes ≥ 1 block, cache after ≤ retain (0), budget 0 |
| | control | `budget=1099511627776` (planted value left in place) |
| recycle, the fix *without* the barrier condition (throwaway build) | fixed | **fails**: `Expected 2293760 to be LessOrEqual 0`. The 8 swept blocks were kept for a recycler that cannot run |

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
`@last_phase_flush_ns` is written, and the recycle condition has one more
load and branch.

Perf A/B [41289615508](https://github.com/sdogruyol/gcry/actions/runs/41289615508),
`0d81deb8` against `07b61d28`, all five runners, nine benches, 15 reps,
Boehm arm, pads `p16 p64 bp16 bp64`. All five runners green.
`keep.txt` holds `../2026-11-01-0.40-keep-rule/keep.py`'s output, and `raw/`
the summaries. Rows slower beyond their spread, timed-section medians (s):

| runner | bench | var vs base | var / p16 / p64 | base / bp16 / bp64 | |
|---|---|---|---|---|---|
| ubuntu-latest | Primes | time +2.8% [+1.5, +8.9], wall +2.4% | 1.457 / 1.424 / 1.433 | 1.427 / 1.451 / 1.429 | pads |
| ubuntu-latest | JsonGenerate | time +2.7% [+2.4, +3.3], wall +1.4% | 1.377 / 1.430 / 1.458 | 1.340 / 1.381 / 1.429 | pads |
| ubuntu-latest | Revcomp | wall +0.4% [+0.2, +0.7] | 1.531 / 1.567 / 1.536 | 1.525 / 1.528 / 1.573 | pads |
| ubuntu-24.04-arm | Revcomp | time +1.0% [+0.6, +1.9], wall +0.9% | 1.253 / 1.239 / 1.239 | 1.239 / 1.240 / 1.237 | pads |
| macos-latest | RegexDna | wall +1.1% [+0.2, +3.0] | 2.587 / 2.505 / 2.538 | 2.523 / 2.549 / 2.597 | pads |
| macos-15-intel | JsonParsePure | time +4.3% [+0.3, +13.9] | 1.740 / 2.051 / 1.753 | 1.643 / 1.706 / 2.102 | pads |

Each flagged row has a var-code median inside or below the base-code range,
so each counts as placement. `windows-latest`: no row slower beyond its spread.
Peak: the only row whose median rose beyond spread is Windows JsonParsePure,
+0.3% [+0.1, +0.4]. Every row is within 1.1× Boehm except Knuckeotide, the
documented exception (var 1.16–1.56×, base 1.16–1.56×).

**Verdict:** the change stays in. Every flagged row is excused by the
same-session pads, and peak is unchanged.

## Checks

Local, each step under the shared lock.

| check | result |
|---|---|
| `verify.sh`: format check | clean |
| `make lint` | 248 inspected, 0 failures |
| `crystal spec -Dgc_none spec/all_specs.cr` | 303 examples, 0 failures |
| `… -Dgcry_block_headers spec/all_specs.cr` | 325 examples, 0 failures |
| `GCRY_DEBUG_INVARIANTS=1 … spec/all_specs.cr` | 303 examples, 0 failures |
| `crystal spec -Dgc_none process_spec` | 338 examples, 0 failures, 2 pending |
| `… -Dgcry_block_headers process_spec` | 339 examples, 0 failures, 2 pending |
| `GCRY_BITMAP_ALLOC=0 … -Dgcry_block_headers process_spec` | 339 examples, 0 failures, 2 pending |
| `process_spec` on Crystal 1.22.2 | 338 examples, 0 failures, 2 pending |
| `make windows-typecheck`, `make darwin-typecheck` | clean |
| `make alloc-entry-frame` | 5 examples, 0 failures |
