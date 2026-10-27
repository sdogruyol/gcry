# Regression 84's *publish-lazy* "double hand-out" (2026-10-22)

Regression 84's *publish-lazy* fixed child
(`process_spec/regression/84_stop_sweep_frozen_freelist_holder_spec.cr`,
header layout, `GCRY_BITMAP_ALLOC=0`, allocation batch 32) failed at
`shared.should be_false` in 11 of 100 runs on the frozen-class-gaps branch and
4 of 40 at `32ce703a` (`../2026-10-22-mprotect-card-reclaim/FINDINGS.md`). In
every failure all three of the worker's stash blocks were on the class list
and there was no second collection. That reads as a double hand-out on the
freelist allocator with allocation batches.

**It is not one.** The spec's batch hook parked the wrong thread. No change
under `src/` was needed.

Branch `r84-double-handout-039`, from `origin/frozen-class-gaps-039` at
`52c0c3f5` (identical to `origin/release-0.39.0` since then). Local host: QEMU
x86-64 guest, 12 vCPU shared with other agents, Crystal 1.21.0. Every heavy
run held `/home/naruto/playground/.scratch/heavy.lock`, one run per hold, each
run bounded by `bench/run_bounded.sh`.

## Mechanism

`freelist84_batch_window` sets `alloc_batch_publish_hook` (*publish*) or
`alloc_batch_pop_hook` (*pop*). Both hooks are global: `publish_alloc_batch_stash`
and `alloc_old_small_batched` (`src/gcry/tlab.cr`) call them on **every**
thread's batch path. The hook parked the first thread to reach it once
`armed` was 1, and the worker set `armed` just before its own allocation. The
lazy windows run two idle threads beside the worker. When one of them was
still starting up, it could do a batch refill of its own (a 192 B class)
inside the worker's armed window and reach the hook first:

1. The idler parks in its publish, under the 192 B class lock, and sets
   `parked = 1`.
2. `parked = 1` lets the main thread go on to `GC.collect`. The worker is not
   parked (`parked` is taken) and runs both 24 576 B allocations through, and
   then reads its stash into `held`, all before the stop.
3. The stop finds the 192 B class lock held, so `sweep_frozen_classes_in_stop?`
   is true and `stop_frozen_sweeps_in_stop` increments, which is what the
   arm asserts. `flush_all_alloc_batches` finds the worker's slot lock free
   and returns its three stash blocks to the 24 576 B class list as FREE,
   as it should.
4. `held` was read before the stop, so it still names those three blocks.
   `freelist84_listed?` finds them on the list and `shared` reads true. No
   thread holds them: the worker's stash is empty after the stop.

Instrumented copy of the spec (`diag-runs.txt`). It records which thread
parked, the size of the block it parked on, the worker's
`heap.collections` after its allocations, and the worker's stash once the
collection has finished:

| runs | parked thread | parked block | worker's collections count | held blocks listed | held blocks FREE | worker stash after the stop |
|---|---|---|---|---|---|---|
| 174 passing | worker | 24 576 B | 1 | none | 0 | 3 (v2) |
| 6 failing (5 of 100, 1 of 80) | not the worker; an idle thread (v2) | 192 B | 0 | `[0, 1, 2]` (the stash) | 3 (v2) | 0 (v2) |

The diagnostic that reported the failure
(`/home/naruto/playground/.scratch/FrozenClassGaps/dbg/r84diag.txt`) shows
the same thing in all 11 of its failures: the worker's `heap.collections`
read 0 after its second allocation, so the worker was never parked.

## Fix

In `freelist84_batch_window`:

- The hook parks only the worker, by `Thread.current.object_id` (regression
  75's filter), and only on a block of the class under test (the exclusion
  window's size filter). It records the thread it parked.
- A bystander thread is created before the worker and waits on `go`. Inside
  the armed window, before the worker's own allocation reaches the hook, the
  worker releases it and waits until it has finished or is parked. The
  bystander allocates 3 072 B twice: first a batch refill that publishes a
  stash, then a pop. Those are the two paths the hooks sit on.
- After the collect and both joins, the parked thread must be the worker
  (`fail "the hook parked a thread other than the worker"`), and the
  bystander must have finished.

This covers all four batch arms (*pop*, *publish*, *pop-lazy*,
*publish-lazy*), since they share the window. The pop arms had the same
construction. They lost the race less often, but nothing kept them from it.

## Red → green

`arm-runs.txt`. *Red* is the extended spec with the hook condition put back to
the old `armed.get == 1 && parked.get == 0` (`/home/naruto/playground/.scratch/R84Handout/dbg/red84.cr`):

| build | arm | result |
|---|---|---|
| unmodified spec at `52c0c3f5` | *publish-lazy* fixed | 197 of 200 pass; 3 fail at `shared.should be_false` |
| extended spec, old hook | *publish-lazy* fixed | 0 of 30 pass, every one at the parked-thread check |
| extended spec, old hook | *pop*, *publish*, *pop-lazy* fixed | 0 of 10 each, every one at the parked-thread check |
| extended spec, new hook | *publish-lazy* fixed | 220 of 220 pass |
| extended spec, new hook | all 12 arms (`GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0`) | 24 examples, 0 failures |

The base rate depends on load: it was 9 of 380 here across the three
measurements (5 of 100 and 1 of 80 instrumented, 3 of 200 unmodified), and 11
of 100 and 4 of 40 in the reports.

## Stress

`stress-batch.txt`: `stw_mt_property_test`, `--release -Dgcry_block_headers`,
`GCRY_BITMAP_ALLOC=0 GCRY_ALLOC_BATCH=8`, `--iterations=200 --workers=2,4`,
seeds 3001–3150, `run_bounded.sh 120`: 150 of 150 pass.

## Checks

| check | result |
|---|---|
| `make format-check` | pass |
| `make lint` | 240 inspected, 0 failures |
| `crystal spec -Dgc_none spec/all_specs.cr` | 296 examples, 0 failures |
| `crystal spec -Dgc_none -Dgcry_block_headers spec/all_specs.cr` | 318 examples, 0 failures |
| `crystal spec -Dgc_none process_spec` | 283 examples, 0 failures |
| `crystal spec -Dgc_none -Dgcry_block_headers process_spec` | 284 examples, 0 failures |
| `GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none -Dgcry_block_headers process_spec` | 284 examples, 0 failures |
| `make bitmap-marks-freelist` | ok (331 and 284 examples, 0 failures) |
| `make windows-typecheck` | pass |
| `crystal build --no-codegen -Dgc_none --cross-compile --target aarch64-apple-darwin samples/hello.cr` | pass |
