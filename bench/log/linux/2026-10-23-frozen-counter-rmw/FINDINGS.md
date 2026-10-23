# Counters a frozen thread overwrote after the stop (2026-10-23)

The in-stop sweep audit (`../2026-10-22-in-stop-sweep-audit/FINDINGS.md`,
row 28 and "Open: reporting counters") left three byte counters open. Each
is written by threads under different locks (or none) and by the stop, and
each write was a plain load and store. A stop suspends by signal (or
`SuspendThread`), so it can freeze a thread between the two; the stop writes
the counter, and the thread, resumed, stores what it computed from the value
before the stop. The stop's write is lost for good.

All three are fixed, each forced red→green by a hook with a control arm
(`process_spec/regression/88_frozen_counter_rmw_spec.cr`). None of them is on
the allocation hit path.

## The three counters

| counter | writers outside the stop | the stop's write | consumers | lost update |
|---|---|---|---|---|
| `@heap_size` | `map_chunk` (no lock); large growth, large recycle and three large releases (`@alloc_lock`); `unqueue_kept_chunk_accounting` (flush, `@alloc_lock` + `@chunk_list_lock`) | in-stop sweep's unmap branch, `sat_sub` per queued chunk | `GC.stats.heap_size`, `GC.prof_stats`, `GC_get_heap_usage_safe`, `GC_get_prof_stats`, `/gc-stats` (`heap_size`, `small_mapped_bytes`), Prometheus `heap_bytes` / `small_mapped_bytes`, trace lines, crash report, `heap_resize` hook and `CrystalTrace.heap_resize`, the OOM warning. **Decisions:** `small_mapped_bytes` feeds the tight-grow collect-before-grow trigger (`Heap#alloc_old_small`, header allocator, `GCRY_TIGHT_GROW=1`); `map_chunk`'s `MADV_POPULATE_WRITE` (heap ≥ 32 MiB, Linux); `filter_freelist_outside`'s step bound | High by every chunk the stop unmapped while a thread was frozen in any of the writes above. Also racy between mutators: `map_chunk`'s `+=` is outside every lock, so two mappers, or a mapper and a large release, lost one another's update with no stop involved. |
| `@dormant_chunk_bytes` | revivals: `bitmap_revive_dormant` (class lock), `install_revived_chunk` (`@alloc_lock` + class lock) | major sweep: zeroed, then every dormant chunk recounted, plus the chunks it made dormant | `flush_pending_dormant_chunks` returns early at zero (the release of dormant pages, RSS); `/gc-stats`; `bench/idle_release.cr` and `bench/idle_rss_after_burst.cr` (`kept_empty`) | A revival frozen between its load and its store put back the pre-stop count minus its chunk: every chunk the stop made dormant vanished, and at zero the flush skipped their pages. |
| `@expl_freed_bytes_since_gc` | `note_explicit_free`, every `GC.free` (no lock) | zeroed after the sweep, every major | `GC.prof_stats` / `GC_get_prof_stats` only | A free frozen across the stop put the previous cycle's bytes back over the zero. |

None of them feeds pacing or the threshold: those read `bytes_since_gc`,
`live_bytes_after_sweep` (`size_class_live_bytes` + large mapped − large
free) and the sweep's own walk.

### `@dormant_chunk_bytes` needed more than an atomic

The major sweep zeroed the counter and recounted the chunks it found
dormant. A revival is two steps — clear DORMANT, subtract the bytes — and a
stop between them broke the count whatever the subtraction was made of:

- `bitmap_revive_dormant` clears the flag first (under `@alloc_lock`, with
  CURSOR, so the chunk is pinned throughout) and subtracts after. The stop's
  recount no longer sees the chunk; the resumed revival then subtracts it
  from a count that does not hold it. Measured: with the subtraction a
  compare-and-set but the recount kept, the fixed child of regression 88's
  dormant arm on the bitmap layout read **drift 131 072 (one chunk) in 3 of
  3 runs**. The freelist path subtracts first and clears the flag after, so
  it passed there; frozen between the two it would overcount by the chunk.
- The after-world (lazy) sweep, the default with more than one mutator,
  zeroes and recounts with the revivers running, so a revival of a chunk the
  walk had not reached yet subtracted it from a partial count.

So the counter is now kept by the transitions alone: the sweep adds a chunk
as it makes it dormant (before it sets the flag, so a reviver that finds the
flag always finds the bytes), and a revival or `reuse_dormant` subtracts as
it clears the flag (`reuse_dormant` did not subtract before, because the
recount covered it). The reset and the recount are gone. Every dormancy
transition is one of those four sites (`ChunkHeader.set_dormant` callers in
`src/`); a dormant chunk is never unmapped (the sweep skips it, the flushes
release only queued chunks), and `destroy_collector` zeroes the counter with
the rest.

## The fix

`Heap#def_shared_counter` (heap.cr) defines `heap_size_add`/`_sub`,
`dormant_bytes_add`/`_sub` and `expl_freed_add` over `Atomic(UInt64)` fields.
`_add` is one atomic add (`lock xadd`; it cannot be frozen half done) and
returns the new value; `_sub` is a compare-and-set loop that saturates at
zero as `sat_sub` did. A compare-and-set frozen after its load fails against
the stop's value and is recomputed from it. The collector's writes use the
same calls (the after-world sweep and the flushes run beside the mutators);
the resets are atomic stores. Readers use the field's `get`.

Research knobs, on the class (`Heap.shared_counter_hook`, called between
each write's load and its store with the counter's name, and
`Heap.shared_counters_atomic = false`: plain loads and stores, the dormant
reset and recount, and `reuse_dormant` not subtracting — the code before).

Cost: the writes sit on `map_chunk` (after an `mmap`), the large paths
(under `@alloc_lock`), revivals, the sweep (per chunk) and `GC.free` (one
`lock xadd` where there was a plain add, and a load of the hook). The
allocation hit path does not touch any of them.

### The heap's layout, and the first keep-rule run

The first version (`8988fdbe`) put the two knobs on each heap and declared
the three atomics by initializer (`@heap_size = Atomic(UInt64).new(...)`).
Both moved the hit path's fields: the knobs added 24 bytes among them, and
an instance variable declared by initializer is laid out apart from one
declared with its type (observed: typing the three restored every offset
below), so the counters left their slots. Offsets
against `release-0.39.0`, read with `offsetof` from a build of each
(`@fast_path` 86 076 → 86 084, `@gc_threshold` 14 344 → 14 352,
`@fit_index` 12 624 → 12 616, `@fit_payload` 12 884 → 12 876,
`@atomic_slack` 12 504 → 12 496, `@bytes_since_gc` 85 792 → 85 800; with
the knobs moved to the class but the counters still inferred, 86 060,
14 328, 12 616, 12 876, 12 496, 85 776: still different). Perf A/B
[39921092926](https://github.com/sdogruyol/gcry/actions/runs/39921092926)
on that commit: Binarytrees slower on four of five runners, timed section
var against base +1.1% [+0.6, +3.4] ubuntu-latest, +2.0% [+0.6, +2.5]
ubuntu-24.04-arm, +1.8% [+0.3, +2.8] macos-latest and +7.1% [+2.5, +9.8]
macos-15-intel, where the speed fell beyond base's spread (152%
[148, 156] → 145% [139, 148] of Boehm): the keep rule failed. The pads
arms did not bring it back (macos-15-intel `prepad16`/`prepad64` 148% /
150% against `baseprepad16`/`64` 153% / 153%), which code placement
would have.

So the knobs are class variables and the counters are declared with their
type (`@heap_size : Atomic(UInt64) = ...`), in the slots of the `getter`s
they replace. Every offset above, and `instance_sizeof(Heap)` (86 784),
is then the base's (`3193e198`).

Perf A/B [39928923987](https://github.com/sdogruyol/gcry/actions/runs/39928923987)
on `3193e198` against `90620b0e` (`release-0.39.0`; its `src/` is
`6fc6665c`'s), ten rows, 15 reps, Boehm arm, pads `p16 p64 bp16 bp64`, all
five runners green. Speed % of Boehm, base → var, and every row whose
median fell below base's interquartile range:

| runner | Binarytrees | slower beyond base's IQR | what the pads arms read |
|---|---|---|---|
| ubuntu-latest | 99% → 102% | JsonParsePure 89 → 87, JsonGenerate 90 → 87, JsonParseSerializable 91 → 89, JsonParsePull 94 → 89, Brainfuck 102 → 96 | placement: var padded by 16/64 reads base's timed section (JsonParsePull 0.377/0.372 s, base 0.372, var 0.414; JsonParseSerializable 0.386/0.402, base 0.411), and base padded by 64 reads var's (Brainfuck 3.394 s, var 3.392; JsonGenerate 0.855, var 0.862). Brainfuck allocates nothing |
| ubuntu-24.04-arm | 102% → 103% | none (Binarytrees timed −3.1%) | — |
| macos-latest | 98% → 94% [88, 98] (base [93, 104]) | none | — (a slow, wide run: Boehm 2.50 s on JsonGenerate against 2.21 s in the first) |
| macos-15-intel | 149% → 144% [136, 152] (base [141, 156]) | Knuckeotide 100 → 95 [92, 109] | timed −0.8% [−11.8, +7.8]; pads 100 / 101 against 99 / 97 |
| windows-latest | 120% → 118% | Primes 108 → 103 | placement: pads 100 / 103 against 102 / 102; timed +4.0% [−0.3, +7.6] |

Peak within 1.1× Boehm on every row but Knuckeotide (the exception, and
no higher: −12% on arm64). JsonGenerate's peak on macos-latest read 0.64× →
0.74× in this run, with the base pad arm `bp16` reaching 0.74× too, and
0.64× → 0.64× in the first run: a bimodal peak on the noisy run.

**Verdict:** no row is slower beyond its spread except where the same-session
pad arms move it as far, both ways round; nothing in the change runs on the
allocation hit path, and the heap's layout is the base's. Binarytrees, the
row the first version cost, is level on all five. After the final push the
branch was rebased onto `release-0.39.0` at `d60fce19`; the offsets were
re-read against that base and are again equal (`@fast_path` 86 124 both).

## Regression 88

Six arms, each child in a process of its own: for each counter, a thread
parks in `shared_counter_hook` between that counter's load and its store;
the main thread collects (sweep in the stop: `lazy_sweep = false`) while it
is parked, and the thread goes on at `:after_start_world`, before the
flushes. The collection writes the counter: unmaps an empty chunk
(`parallel_empty_chunk_munmap`, `empty_chunk_retain = 0`), makes an empty
chunk of a second class dormant while the thread revives the first one, or
zeroes the explicit-free bytes. Then the counter is read against a walk
(`Invariant.heap_size_drift`, `Invariant.dormant_bytes_drift`, new) or, for
the explicit frees, against the one free made after the zero. The fixed arms
also require `live_objects` and `free_bytes` drift 0.

Linux x86_64, local, each child run directly (control markers):

| layout | `heap_size` control | `dormant` control | `expl_freed` control | fixed arms |
|---|---|---|---|---|
| bitmap, headerless (default) | drift −524 288 = the 524 288 the stop unmapped | drift +131 072 (counter 393 216) | 40 960 against the parked free's 4 096 | green, drift 0 |
| bitmap, `-Dgcry_block_headers` | drift −524 288 = unmapped | drift +131 072 | 40 960 vs 4 096 | green |
| freelist (`GCRY_BITMAP_ALLOC=0`, headers) | drift −393 216 = unmapped | drift +131 072 | 40 960 vs 4 096 | green |

On the other platforms, `probe/counters` (push-triggered,
`.github/workflows/probe-counters.yml` on that branch): regression 88 built
debug and `--release` in the three layouts, three runs each, and every
control child run on its own for its marker.

- Run [39921278741](https://github.com/sdogruyol/gcry/actions/runs/39921278741)
  on `8988fdbe`: `macos-latest`, `macos-15-intel`, `ubuntu-24.04-arm` and
  `windows-latest` 72 of 72 runs green; every control child lost the stop's
  write (72 of 72 markers). `heap_size` drift = −(bytes the stop unmapped)
  every time (393 216 to 1 048 576 by platform and layout), `dormant` drift
  one chunk (131 072; 262 144 on macOS, whose chunks are larger), and
  `expl_freed` 40 960 against the parked 4 096 everywhere. `windows-11-arm`
  failed to build there (the probe set `CC` to `crystal.exe`, which Crystal
  takes as its linker); rerun as
  [39925208158](https://github.com/sdogruyol/gcry/actions/runs/39925208158):
  18 of 18 green, 18 of 18 control markers.
- Run [39933051731](https://github.com/sdogruyol/gcry/actions/runs/39933051731)
  on `3193e198` (the final source), all five: `macos-latest`,
  `macos-15-intel`, `ubuntu-24.04-arm`, `windows-latest`, `windows-11-arm`
  90 of 90 runs green, 90 of 90 control markers.

## Other counters the stop writes, checked

Every ivar the sweep writes (`collect_sweep.cr`) and the post-sweep resets,
crossed with every read-modify-write in the mutator files (`heap.cr`,
`bitmap_alloc.cr`, `tlab.cr`, `c_abi.cr`, `gc_override.cr`, `finalizer.cr`):

- `@live_objects`, `@free_bytes`, `@bytes_since_gc`, `@nursery_alloc_bytes`:
  atomic RMWs on the mutator side whenever more than one thread exists
  (`counters_atomic?`; `heap_counters_atomic` is set at the second thread);
  the stop's plain stores are safe against them. `@bytes_since_gc`'s reset
  against a credit claimed before it is the audit's row 15 (attribution).
- `@unmapped_bytes`: every writer holds `@alloc_lock` (the flush's
  `flush_release_runs` too); the stop never writes it.
- `@released_chunk_bytes`, `@last_empty_unmap_bytes`, `@fully_free_chunk_bytes`,
  `@bytes_reclaimed_since_gc`, `@size_class_live_bytes`: collector only.
- `@large_mapped_bytes`, `@large_free_bytes`: every writer holds
  `@alloc_lock`; the in-stop sweep defers the large cache to
  `flush_pending_large_cache`.
- `@freelist_rebuild_request(_nursery)`: a mask, not a counter.
  `discard_refill_across_collection`'s `|=` frozen across the sweep's
  read-and-zero stores the old bits back with its own: the next sweep
  rebuilds those classes once more (idempotent; TLABs are flushed before a
  sweep). The bits the sweep sets back for frozen classes are a subset of
  the old request plus bitmap classes, which rebuild nothing. Benign.

## Open: large-cache counters, not the stop

Found on the way, not reproduced: the collector writes
`@large_recycle_budget = @large_free_bytes` (or 0), `@large_alloc_since_major
= 0` and `@large_cache_hits`/`_misses = 0` after the flushes with no lock
(`collect.cr`, `run_collection_body`), while `alloc_large`, `grow_large` and
`recycle_large_mapping` read-modify-write them under `@alloc_lock`, and
`map_chunk` spends `@large_recycle_budget` for size-class chunks under the
class lock only. These are running threads, not a frozen one, but the loss
has the same shape, and the three feed the large-cache trim (`Heap#allocate`'s
`@large_free_bytes > @large_recycle_budget`, `large_recycle_keep`, the
per-major `keep = @large_alloc_since_major`) and the adaptive retain. Effect
bounded to RSS (more or less large cache kept for one cycle).

## Checks

On the branch rebased onto `release-0.39.0` at `d60fce19` (`cc087149`),
each under the shared lock, one at a time, bounded by `bench/run_bounded.sh`
(the same set passed on `8988fdbe` and on `3193e198`, with the same counts):

| check | result |
|---|---|
| `crystal tool format --check src spec process_spec bench samples` | clean |
| `make lint` | 241 inspected, 0 failures |
| `crystal spec -Dgc_none spec/all_specs.cr` | 296 examples, 0 failures |
| `crystal spec -Dgc_none -Dgcry_block_headers spec/all_specs.cr` | 318 examples, 0 failures |
| `crystal spec -Dgc_none process_spec` | 298 examples, 0 failures |
| `crystal spec -Dgc_none -Dgcry_block_headers process_spec` | 299 examples, 0 failures |
| `GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none -Dgcry_block_headers process_spec` | 299 examples, 0 failures |
| `make alloc-entry-frame` | 5 examples, 0 failures |
| `make windows-typecheck` | both targets type-check |
| `crystal build --no-codegen -Dgc_none --cross-compile --target aarch64-apple-darwin samples/hello.cr` | clean |
