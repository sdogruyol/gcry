# Large-cache counters reset after the flushes with no lock (2026-11-01)

The ROADMAP item "Large-cache counters written after the flushes with no
lock" (found during `../2026-10-23-frozen-counter-rmw/`, not reproduced
there). Confirmed, forced red→green, fixed. Branch `large-cache-040`, from
`origin/release-0.40.0`.

## The hazard

Every writer, its lock, and what reads the counter, on the 0.39.0 tree
(`c0d570c5`):

| counter | mutator writers (lock) | collector write (lock) | consumers |
|---|---|---|---|
| `@large_recycle_budget` | `alloc_large` fresh reserve, `recycle_large_mapping` (two), `grow_large`: `x = sat_sub(x, n)` under `@alloc_lock`; `map_chunk` for every fresh mapping, **a size-class chunk under its class lock only** | `= @large_free_bytes` (recycling) or `= 0` after the flushes, every collection, no lock (`collect.cr`, `run_collection_body`) | **Decisions:** `Heap#allocate`'s trim gate (`@large_free_bytes > budget`, every allocation under recycling, the Linux default) and `large_recycle_keep` (what the mutators' trims and `GC.free` keep in the cache) |
| `@large_alloc_since_major` | `alloc_large` (`&+=`), `grow_large` (`&+=`), under `@alloc_lock` | read as the major's `keep`, then `= 0` after the flushes, no lock | **Decision:** what a recycling major keeps in the large cache (`trim_large_cache(keep)`) |
| `@large_cache_hits` / `_misses` | `take_large_free` / `alloc_large` (`+= 1`), under `@alloc_lock` | read for the adaptive retain, then `= 0`, every major, no lock | **Decision:** `@large_cache_retain` doubled (hit rate > 50%) or halved (< 10%), which is the floor of `large_recycle_keep` and the non-recycling trim's retain; `GC.stats`-style readers (`large_cache_hits`) |

A plain `x = f(x)` that loaded before the collector's store and stored after
it put the old cycle's value back over the reset, for good:

- budget: the cache may hold, until the next collection, what the budget
  of the cycle before allowed (more RSS, or, if that was smaller, fewer
  recycles);
- since-major: the next major keeps two cycles' large bytes for recycling;
- hits/misses: the next adaptive decision reads the cycle before's counts
  too. Separately from the store race, counts made between the collector's
  read and its reset were in neither cycle.

These are running threads, not a thread a stop froze (regression 88's
family): the resets run after `start_world`, beside every allocating thread.
The effect is RSS and recycling hit rate, not memory safety.

## The fix

All four are `Atomic(UInt64)` and written through `def_shared_counter`
(`heap.cr`), as 0.39.0 did for `@heap_size`, `@dormant_chunk_bytes` and
`@expl_freed_bytes_since_gc`:

- mutator adds (`large_since_add`, `large_hits_add`, `large_misses_add`) are
  one `lock xadd`; a count made after the reset lands on it;
- budget subtractions (`large_budget_sub`) are a saturating compare-and-set,
  which fails against the reset and is recomputed from it;
- the collector takes the per-major counts with one swap each
  (`def_shared_counter`'s new `_take`), before the trims, so a count made
  while they run belongs to the next major instead of to neither; the major's
  `keep` is the value the swap returned;
- the budget is set with an atomic store.

Taking `@alloc_lock` for the resets instead would not have covered
`map_chunk`, which cannot take it (the large path already holds it across
`alloc_large` → `map_chunk`, and the spinlock is not reentrant).

`Heap#allocate`'s gate reads the budget with `get(:relaxed)`: a plain load
on x86_64 and arm64, as the plain field was (a sequentially consistent load
is `ldar` on arm64). `large_recycle_keep` reads it the same way.

The control arm is the existing class knob `Heap.shared_counters_atomic =
false` (plain loads and stores, and the take a load then a store of zero).
The test hook is the existing `Heap.shared_counter_hook` plus two new
`post_stw_hook` stage pairs around the resets (`:before_large_take` /
`:after_large_take`, `:before_large_budget` / `:after_large_budget`); nothing
between a pair takes a lock.

### Layout

`@large_cache_hits`/`_misses` and `@large_recycle_budget` were typed
declarations and stay typed; `@large_alloc_since_major` was declared by
initializer and stays so (`Atomic(UInt64)` is the size of a `UInt64`).
`instance_sizeof(Gcry::Heap)` and the hit path's offsets against the base,
read with `offsetof` from a build of each (`c0d570c5` and this branch), are
equal: `instance_sizeof` 86 832, `@fast_path` 86 124, `@gc_threshold`
14 368, `@fit_index` 12 648, `@fit_payload` 12 908, `@atomic_slack` 12 504,
`@bytes_since_gc` 85 840, and the four counters themselves
(`@large_recycle_budget` 14 152, `@large_alloc_since_major` 86 176,
`@large_cache_hits` 6 552) where they were.

## Regression 89

`process_spec/regression/89_large_cache_counter_reset_spec.cr`, eight
children, each in a process of its own. Each counter: a thread waits; at the
first stage of the pair the collector lets it go and waits until it has
parked in `shared_counter_hook` between its load and its store (holding
`@alloc_lock`, or the class lock for the budget's `map_chunk`); the collector
resets; at the second stage it releases the thread, which stores. Sweep in
the stop and no recycling (so the cache is left alone until after the take).

Linux x86_64, local, default layout, each child run directly:

| counter | the thread's write | control (marker) | fixed |
|---|---|---|---|
| since | `alloc_large`'s add | since = 761 856 = 557 056 before + 204 800 parked | = 204 800 |
| hits | `take_large_free`'s add | hits = 2 = 1 before + 1 | = 1 |
| misses | `alloc_large`'s add | misses = 5 = 4 before + 1 | = 1 |
| budget | `map_chunk`'s subtraction (size-class chunk, class lock) | budget = 2^40 − 2 228 224 (the stale value less the chunks mapped since it was set) over the collection's 0 | = 0 |

The parent requires each control child's marker (`counter89: control lost
the collector's <counter> reset`) and each fixed child green. The code is the
same on every platform (Crystal atomics, no OS calls), so no per-platform
probe was run.

## Perf

What changed on a default path: `Heap#allocate`'s trim gate reads the budget
through `get(:relaxed)` (after `@large_recycle`, so only on Linux, where
recycling is the default); `alloc_large`, `take_large_free` and
`grow_large` count with `lock xadd` under `@alloc_lock`; `map_chunk` spends
the budget with a compare-and-set after its `mmap`; the collector swaps
three counters per major. The heap's layout is the base's (above).

Perf A/B [41203320527](https://github.com/sdogruyol/gcry/actions/runs/41203320527)
on `0842c37b` against `bf607374` (`release-0.40.0`), ten rows, 15 reps,
Boehm arm, pads `p16 p64 bp16 bp64`, all five runners green. Speed % of
Boehm, base → var, for every row whose median fell below base's
interquartile range, and what the same session's pad arms read:

| runner | slower beyond base's IQR | pads (p16 / p64 / bp16 / bp64) |
|---|---|---|
| ubuntu-latest | JsonParseSerializable 106 [105, 107] → 104; JsonParsePull 107 [105, 107] → 104; RegexDna 97 [97, 98] → 96; Brainfuck 101 [100, 103] → 99 | 109 / 105 / 107 / **104**; 109 / 106 / 107 / **104**; 99 / 97 / 99 / **96**; 100 / 102 / **97** / **97**: base padded by 64 reads var's, var padded by 16 reads above base. Brainfuck allocates nothing |
| ubuntu-24.04-arm | none | — |
| macos-latest | JsonGenerate 104 [102, 108] → 100 | 103 / 102 / 102 / 104: var padded is back in base's range |
| macos-15-intel | Binarytrees 151 [148, 156] → 141 (timed +9.3%) | 144 / 144 / 145 / 147 |
| windows-latest | RegexDna 101 [100, 101] → 99; Revcomp 102 [101, 103] → 99 | 98 / 100 / 100 / **99**; 96 / 101 / 101 / **97**: base padded by 64 reads var's |

Binarytrees on macos-15-intel was run again on its own,
[41211375729](https://github.com/sdogruyol/gcry/actions/runs/41211375729)
(Binarytrees and Primes, 15 reps, same pads): timed section base 1.408 s,
var 1.507 s, var padded 1.506 / 1.567 s, **base padded 1.562 / 1.489 s**.
Base padded by 16 is slower than var, and base's padded arms (1.489–1.562 s)
overlap var's three (1.506–1.567 s): placement, on the same row and runner
whose layout sensitivity `../2026-10-23-frozen-counter-rmw/` measured. On
Darwin `@large_recycle` is false, so the changed gate does not read the
budget there. Primes in that run: 102 [95, 104] → 97, inside base's range.

Peak within 1.1× Boehm on every row but Knuckeotide (the exception) and
Brainfuck on macos-latest (1.24× → 1.23×, the base's too; a 5 MiB process
that allocates nothing).

**Verdict:** every row that read slower is moved as far by the same
session's pad arms, both ways round; the heap's layout is the base's.

## Checks

Local, each under the shared lock, one at a time, bounded by
`bench/run_bounded.sh`. The specs ran on the branch over `bf607374`; after
the rebase onto `80d23a9d` (ameba pinned, two spec arguments renamed) the
format check and lint were run again.

| check | result |
|---|---|
| `crystal tool format --check src spec process_spec bench samples` | clean |
| `make lint` (ameba ~> 1.7.0) | 243 inspected, 0 failures |
| `crystal spec -Dgc_none spec/all_specs.cr` | 302 examples, 0 failures |
| `crystal spec -Dgc_none -Dgcry_block_headers spec/all_specs.cr` | 324 examples, 0 failures |
| `crystal spec -Dgc_none process_spec` | 314 examples, 0 failures |
| `crystal spec -Dgc_none -Dgcry_block_headers process_spec` | 315 examples, 0 failures |
| `GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none -Dgcry_block_headers process_spec` | 315 examples, 0 failures |
| `make alloc-entry-frame` | 5 examples, 0 failures |
| `make windows-typecheck` | clean |
| `make darwin-typecheck` | clean |
