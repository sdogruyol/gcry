# The mprotect dirty-page scan against a chunk set that moved since the arm

Reported by another audit (LargeCacheIncr), on base `07b61d28` too: with
`-Dgcry_block_headers`, the nursery on and `heap.prefer_mprotect_barrier =
true`, `minor_collect; GC.malloc(300_000); GC.free(that); minor_collect`
dies with SIGSEGV in the second minor, 3 of 3. Without the malloc/free, or
on the soft-dirty backend, it passes.

Two defects, both in `Heap#scan_mprotect_pages` (`src/gcry/barrier.cr`),
and both the same shape: the mprotect barrier's cards are sized to the heap
span at the arm (`arm_mprotect_on_old_chunks` →
`mprotect_set_heap_range(@heap_min, @heap_max)`), and the dirty-page scan of
the next minor — or of an incremental cycle's last slice — runs against
them after the chunk set has moved on. The report's repro reaches the first;
an env-knob-only program reaches the second as well.

## 1. The re-protect makes a page no card covers read-only ("outside")

After the scan, the old chunks are protected again "for the next mutator
window", walking the chunks as they are now. A chunk mapped since the arm
can lie outside the cards: a large allocation gets a mapping of its own, and
Linux places new mappings below the existing ones.
`mprotect_protect_range` set the protected bits only inside the cards
(`note_protected` clips) but protected the whole range. The sweep of the
same collection then rebuilds the chunk list (`collect_sweep.cr:520`,
`ChunkHeader.link(chunk, kept)` for every kept chunk, whenever it relinks:
inside the stop, or after it with one mutator, `sweep_relink_now?`),
writing the chunk's header, live or freed; the fault has no card to claim it
(`mprotect_claim` returns false for an address below `base`); the handler
retries it once (`mprotect_unclaimed`) and then restores Crystal's handler,
which prints "Invalid memory access" and exits 11.

The report's repro under gdb (`handle SIGSEGV nostop pass`, breakpoints on
the barrier's entry points; ASLR off):

```
set_heap_range low=0x7ffff5dbf000 high=0x7ffff7e2f000      # the first minor's arm
minor1 barrier=Mprotect
mmap len=0x4a000                                           # GC.malloc(300_000)
protect 0x7ffff5d55000-0x7ffff5d9f000                      # second minor, scan's re-protect: below the cards
protect 0x7ffff77e0000-0x7ffff7800000 ...                  # the rest, inside
UNCLAIMED addr=0x7ffff5d55000 code=2                       # SEGV_ACCERR, twice
  #3 ChunkHeader.set_next (chunk=0x7ffff5d55000)  block.cr:677
  #4 ChunkHeader.link                             block.cr:623
  #5 Heap#sweep (major=false, after_world=true)   collect_sweep.cr:522
  #8 Heap#minor_collect
0x00007ffff5d55000 0x00007ffff5d9f000 r--p                 # /proc/maps at the crash
```

The free is not needed where the sweep relinks: a large block kept across
the second minor (`nmp_keep.cr`, one mutator, written after it)
crashes the same way, 3 of 3; gdb shows the fault at the start of its own
0x4a000-byte chunk, protected once, by the scan's re-protect. On the
incremental path (`heap.incremental_auto`, `collect_a_little` slices,
`prefer_mprotect_barrier`, headerless layout), a *small* chunk mapped during
the cycle below the cards is re-protected by the last slice's scan and its
sweep dies writing the chunk's occupancy bitmap
(`Kernels::Scalar#sweep_words` under `sweep_small_bitmap`, address
`chunk + 0x20`): base 2 of 3 and 3 of 4, v0.38.0 2 of 3, v0.39.0 1 of 3.

## 2. The scan reads a dirty page whose chunk is gone ("stale")

The scan walked every dirty bit in the cards. A dirty bit outlives its
chunk. From an env-knob-only program (`GCRY_NURSERY=4194304
GCRY_MPROTECT_BARRIER=1`, strings plus a 200 KiB `Bytes` every 500
iterations, four kept; `nmp_env2.cr`), gdb with every barrier fault's
backtrace:

```
ARM 0x7fffef659000-0x7ffff7c00000                          # a minor's arm
FAULT 0x7fffef760038 code=2                                # claimed: page dirty
  #3 Heap#detach_large_cache   heap.cr:3826                # cached large chunk, protected at the arm
  #4 Heap#trim_large_cache     heap.cr:3732
  #5 Heap#allocate             heap.cr:1848                # on the allocation path
munmap 0x7fffef760000-0x7fffef794000
  #2 Heap#release_large_chain  heap.cr:3568                # the same chunk, gone
  #3 Heap#trim_large_cache     heap.cr:3763
FAULT 0x7fffef760000 code=1                                # SEGV_MAPERR: nothing mapped
  #3 Heap#scan_range_for_barrier_pointers barrier.cr:248
  #4 Heap#scan_mprotect_pages             barrier.cr:211
  #6 Heap#scan_old_for_nursery_pointers   collect_mark.cr:797
UNCLAIMED addr=0x7fffef760000 code=1
```

A `SEGV_MAPERR` is never the barrier's (`mprotect_fault` claims only
`SEGV_ACCERR`), so it goes to Crystal's handler at once. With only the first
fix applied this program still crashed 2 of 2, which is how the second was
found.

## Fix

- `scan_mprotect_pages` walks the dirty pages chunk by chunk
  (`Platform.each_mprotect_dirty_page(low, high)`, now ranged: whole pages
  inside the range and the cards, the rounding `mprotect_protect_range`
  uses, zero words skipped whole). Dormant chunks are skipped: no objects.
- On an incremental slice (`nursery_only: false`) its re-protect checks
  `Platform.mprotect_cards_cover?(@heap_min, @heap_max)`. When the heap
  has outgrown the cards it does what the arm does —
  `disarm_mprotect_barrier` (unprotect every chunk, retire the cards), then
  `arm_mprotect_on_old_chunks` (cards sized to the heap now, dirty bits
  clear, old chunks protected), inside the stop, after the dirty bits were
  consumed. A slice that does not finish lets the mutators run under this
  protection, so the chunk mapped since the arm must be tracked from here.
  A minor skips the rebuild (review, finding 2): it ends in
  `arm_page_barrier_after_collect`, which replaces the cards before any
  mutator write matters, so the rebuild only added a per-chunk `mprotect`
  and a `malloc` to the pause.
- `mprotect_protect_range` protects only what the current cards cover, and
  nothing when there are none. Before, either left every protected page
  unclaimable.
- No cards, no barrier (review, finding 1). `mprotect_set_heap_range`
  gives up on a span over 16 Mi pages or a refused `malloc` (and its page
  count is now compared before `to_i32`, which raised on a span past 2^31
  pages). With the clip, an arm or rebuild that got no cards used to leave
  the backend `Mprotect` and blind: the scans saw no bits and returned
  true, and an incremental cycle finished on a mark that missed every store
  after it. Now `arm_mprotect_on_old_chunks` returns whether it got cards,
  and `drop_mprotect_without_cards` sets the backend to `None`.
  `incremental_barrier_possible?` declines a cycle up front when the span
  cannot have cards (`Platform.mprotect_span_pages`), and `begin_incremental`
  drops one whose arm left no barrier. In `collect_a_little` a termination
  scan that takes the barrier down — no cards on the rebuild, or the
  existing too-dirty fallback, which said "let caller full-scan" and never
  did — ends the cycle in a full collection (`collect`, after the slice's
  stop) instead of finishing on that mark; counted in
  `inc_barrier_lost_collections`. The soft-dirty paths that return false
  keep finishing as before [noted, not changed: a soft-dirty scan that
  returns false in the termination finishes the cycle the same way].

Research toggles restore each piece for the control arms:
`Platform.mprotect_cards_cover_protection` (the clip and the card
replacement), `mprotect_dirty_scan_by_chunk`, `mprotect_rebuild_outgrown_cards`
(the replacement only) and `mprotect_drop_without_cards`;
`mprotect_refuse_cards` makes `mprotect_set_heap_range` give up.

## Regression 99

`process_spec/regression/99_mprotect_protect_outside_cards_spec.cr`, Linux;
every arm in its own process, a skip marker (with its reason) where the
construction cannot be built. *outside* and *stale* need the header layout
(nursery); *rebuild* and *nocards* run on both.

- *outside*: arm with a minor; `GC.malloc` 16 MiB (bigger than any hole in
  the spec runner's heap; the child checks with `mprotect_cards_cover?` and
  skips if it landed inside); `large_cache_retain` raised so the free keeps
  it cached; `GC.free`; second minor. Held live instead, the block did not
  reach the window in the spec runner (the control survived, 2 of 2)
  [INFERENCE: that sweep did not relink, or the chunk was not protected;
  not traced].
- *stale*: a 1 MiB block held across the arm in a class variable; `GC.free`
  (its first page dirtied, checked); `trim_large_cache(0, defer: false)`
  (unmapped, checked); second minor.
- *rebuild* and *nocards* share a window: automatic collection off, a white
  20 000-node chain and a white 64-byte object hidden as complements, the
  stack below zeroed, `collect_a_little(1)` to begin; then, inside the
  cycle, a 64-byte holder allocated black in a protected chunk is given the
  chain (a dirty page the termination scan will find, leaving that slice
  unfinished) and a 16 MiB block is mapped outside the cards; slices of
  4096 marks run until the termination scan has run.
  - *rebuild*: after that slice the block must be covered by the cards and
    a write to it must set a dirty bit.
  - *nocards*: `mprotect_refuse_cards` before the slices; the object is
    pinned on this stack after the root scan and, after the slice, stored
    into a second black holder. Fixed: that slice ended the cycle in a full
    collection (`inc_barrier_lost_collections` 1, backend `none`), which
    found the object on the stack; it is alive, and alive after one more
    collection. Control: the cycle runs out on the blind barrier and the
    object is free afterwards (slices never scan a stack after the first
    stop, so only the unrecorded store held it).

30 runs per arm (header layout; headerless where it runs):

| arm | fixed ran to its end | control's mark | died (exit 11, "Invalid memory access") | skipped |
|---|---|---|---|---|
| outside fixed | 30 | — | 0 | 0 (headerless: 30, no nursery) |
| outside control | 0 | — | 30 (`ChunkHeader.link` ← `sweep`) | 0 |
| stale fixed | 30 | — | 0 | 0 |
| stale control | 0 | — | 30 (`scan_range_for_barrier_pointers` ← `scan_mprotect_pages`) | 0 |
| rebuild fixed | 30 / headerless 30 | — | 0 | 0 |
| rebuild control | 0 | 30 / headerless 30 ("covered: false, its write recorded: false") | 0 | 0 |
| nocards fixed | 30 / headerless 30 | — | 0 | 0 |
| nocards control | 0 | 30 / headerless 30 ("alive: false") | 0 | 0 |

The first *nocards* build had both arms backwards (fixed swept the object,
control kept it): the object was marked at the cycle's begin from stale
slots in the collector's own frames, and in the fixed arm it was held on
the stack only as the complement it was computed from. The window now
zeroes 64 KiB of stack below it first, and pins the pointer through a
non-inlined store.

`each_mprotect_dirty_page` takes a range now; regressions 83 and 87 pass
the page they ask about.

## Repro matrix (x86_64 Linux host, Crystal 1.21.0)

| program | base 07b61d28 | fix | v0.39.0 | v0.38.0 |
|---|---|---|---|---|
| `nmp.cr` (the report's) | 3/3 crash | 5/5 + 3/3 pass | 3/3 crash | 3/3 crash |
| `nmp_keep.cr` (no free) | 3/3 crash | 5/5 + 3/3 pass | — | — |
| `nmp_inc2.cr` headers (API incremental) | 2/3 crash | 3/3 pass | — | — |
| `nmp_inc2.cr` headerless | 2/3 crash | 5/5 + 3/3 pass | 1/3 crash | 2/3 crash |
| `nmp_env2.cr`, `GCRY_NURSERY=4194304 GCRY_MPROTECT_BARRIER=1` | 5/5 crash | 5/5 pass (73–145 minors each) | 3/3 crash | 3/3 crash |
| `nmp_env2.cr`, `GCRY_INCREMENTAL=1 GCRY_MPROTECT_BARRIER=1` (both layouts) | 4/4 pass | 4/4 pass | — | — |
| `nmp_env2.cr`, `GCRY_NURSERY=4194304` alone | 4/4 crash (`scan_mprotect_pages`) | 5/5 pass (ends on `soft_dirty`) | — | — |
| `pattern_fuzz` hdr `--phases=40`, `GCRY_NURSERY=262144 GCRY_MPROTECT_BARRIER=1` | 3/3 crash | 3/3 pass | — | — |
| `pattern_fuzz` `--phases=40`, `GCRY_INCREMENTAL=1 GCRY_MPROTECT_BARRIER=1`, both layouts | 6/6 pass | 6/6 pass | — | — |

The programs are not in the tree (scratch, `nmp*.cr`); each is a dozen
lines of the shape described above.

## Reach and affected releases

The mprotect backend is armed only with a nursery (`GCRY_NURSERY=<bytes>`,
header layout only) or incremental marking (`GCRY_INCREMENTAL=1`); both are
off by default on every platform, so the default configuration arms no
barrier and never runs this code. With either opt-in the backend is
mprotect:

- with `GCRY_MPROTECT_BARRIER=1`, anywhere on Linux;
- from the start on aarch64 Linux, which has no soft-dirty;
- on x86-64 Linux, after a minor finds more soft-dirty pages than
  `soft_dirty_max_pct`: `scan_softdirty_pages` sets
  `@soft_dirty_skip_until_major`, and the next arm's
  `select_barrier_backend` falls through to mprotect, which the process GC
  allows (`allow_mprotect_barrier`), until the next major. That is why
  `GCRY_NURSERY` alone crashes base on this host (the backtrace is in
  `scan_mprotect_pages`, with no mprotect knob set).

Probe run 41299975823 (push-triggered, deleted afterwards; base `07b61d28`
against the fix `9ba2744a` (the same source, rebased as `530afd6e`), Crystal 1.21.0, header build, **`GCRY_NURSERY`
as the only knob**):

| runner | barrier at exit | `nmp_env2`, `GCRY_NURSERY=262144` | `pattern_fuzz --phases=40`, `GCRY_NURSERY=262144` | `GCRY_INCREMENTAL=1` backend |
|---|---|---|---|---|
| ubuntu-24.04-arm (7.0.0-1017-azure, no soft-dirty in the kernel config) | mprotect | base 5/5 crash, fix 5/5 pass (498 minors) | base 3/3 crash, fix 3/3 pass | mprotect |
| ubuntu-latest (x86-64, same kernel) | soft_dirty | base 5/5 crash, fix 5/5 pass (498 minors) | base 3/3 crash, fix 3/3 pass | soft_dirty |

So every Linux user of the nursery is exposed, and on aarch64 Linux every
user of incremental marking runs this scan.

Affected: 0.38.0 and 0.39.0, reproduced above. The scan's global dirty
walk and its re-protect are textually the same in v0.35.0, v0.36.0 and
v0.37.0 (`git show <tag>:src/gcry/barrier.cr`) [INFERENCE: affected too,
not run].

In practice the nursery path is the one that bites: any program that
allocates and drops large objects while the nursery runs. On the
incremental path the env-knob programs did not crash (`nmp_env2` 4/4 here
and 2/2 on the runners, `pattern_fuzz` 6/6); only the API-driven slices
did. [INFERENCE] the automatic incremental cycles of those programs rarely
end a slice's scan with a chunk outside the cards and a sweep write into
it, and a large chunk dirtied and unmapped between slices needs the cache
trim inside a cycle.

## Why no gate caught it

`bench/stress_overnight.sh` had no loop with the nursery or the mprotect
barrier. CI runs the nursery in `make nursery-headers` /
`nursery-tlab-smoke` (soft-dirty on x86 runners, small and short) and
`GCRY_NURSERY` / `GCRY_MPROTECT_BARRIER` only in a hello-world env check.
Added: `pattern-fuzz-nursery-mprotect` (header build, `GCRY_NURSERY=262144
GCRY_MPROTECT_BARRIER=1`, 20 runs of 200 phases, 300 s each) and
`pattern-fuzz-incremental-mprotect` (`GCRY_INCREMENTAL=1
GCRY_MPROTECT_BARRIER=1`, 10 runs of 100 phases, 600 s each), in the `fuzz`
shard of `stress.yml` through its `pattern-fuzz.*` pattern. The first
crashed base in 3 of 3 seeds at 40 phases (and `GCRY_NURSERY` alone did on
both runners in the probe, so a plain nursery loop would have caught it
too). Found on the way: `pattern-fuzz-headers-freelist` ran the headerless
build, where `GCRY_BITMAP_ALLOC=0` is ignored (warned on stderr), so it
repeated `pattern-fuzz`; it now runs the header build it is named for.
Smoke of the three on the fix, scale 0.05 under the shared lock, 200 phases
each: `pattern-fuzz-headers-freelist` 2/2, `pattern-fuzz-nursery-mprotect`
1/1, `pattern-fuzz-incremental-mprotect` 1/1. One 200-phase run timed alone
under the lock: nursery+mprotect 51 s, incremental+mprotect 208 s (hence
its halved phases and doubled limit), headers-freelist 34 s.

## Keep rule

Not run. Every changed function — `scan_mprotect_pages`,
`mprotect_protect_range`, `each_mprotect_dirty_page`,
`mprotect_cards_cover?` — runs only with the mprotect backend armed, which
needs one of the opt-ins above; the default path arms no barrier.

## Checks

On the fix (`9ba2744a`, rebased as `530afd6e`, plus docs), x86-64 Linux host:

| check | result |
|---|---|
| `crystal tool format --check src spec process_spec bench samples` | clean |
| `make lint` (after `rm -rf lib/ameba bin/ameba`) | 248 inspected, 0 failures |
| `crystal spec -Dgc_none spec/all_specs.cr` | 303 examples, 0 failures |
| the same, `-Dgcry_block_headers` | 325 examples, 0 failures |
| the same, `GCRY_DEBUG_INVARIANTS=1` | 303 examples, 0 failures |
| `crystal spec -Dgc_none process_spec` | 338 examples, 0 failures, 2 pending |
| the same, `-Dgcry_block_headers` | 339 examples, 0 failures, 2 pending |
| the same, `GCRY_BITMAP_ALLOC=0` | 339 examples, 0 failures, 2 pending |
| `process_spec` on Crystal 1.22.2, headerless / headers | 338 / 339 examples, 0 failures, 2 pending |
| `make windows-typecheck`, `make darwin-typecheck` | ok |
| `make alloc-entry-frame` | 5 examples, 0 failures |

After the last edits (regression 99's text and comments only): format and
lint clean; regression 99 headerless 8/8 (children skip), headers 8 plus 83
and 87 (26 examples, 0 failures), headers on Crystal 1.22.2 8/8; both
typechecks ok; the four arms 30 of 30 each as in the table above.

After the review's three changes (no cards → no barrier and a full
collection, rebuild on incremental slices only, the *rebuild* and *nocards*
constructions), on the full tree: format and lint clean (248 inspected);
`spec/all_specs.cr` 303 / 325 / 303 (headerless, headers, invariants), 0
failures; `process_spec` 346 / 347 / 347 (headerless, headers, headers with
`GCRY_BITMAP_ALLOC=0`), 0 failures, 2 pending; `process_spec` on Crystal
1.22.2 346 / 347, 0 failures; windows and darwin typechecks ok;
`make alloc-entry-frame` 5 examples, 0 failures. `pattern_fuzz --phases=40`
seeds 1–3 with `GCRY_NURSERY=262144 GCRY_MPROTECT_BARRIER=1` (headers) and
`GCRY_INCREMENTAL=1 GCRY_MPROTECT_BARRIER=1` (headerless): 6 of 6 pass.

Rebased on `87ccf4f4` (the incremental finish's large-cache settle) and run
again: format and lint clean (249 inspected); `spec/all_specs.cr` 303 / 325
/ 303, 0 failures; `process_spec` headerless 358 and headers with
`GCRY_BITMAP_ALLOC=0` 359, 0 failures; Crystal 1.22.2 358 / 359, 0
failures; typechecks ok; `make alloc-entry-frame` 5 / 0; regression 99's
eight arms 30 of 30 each as tabled (headerless *rebuild*/*nocards* too).
The headers `process_spec` run failed once, in regression 61's "collection
reclaims the target" example (its positive control expects a conservative
collection to free a target). Three more runs on this tree passed. On base
`87ccf4f4` alone, the same example failed in 1 of 3 runs. That is a flake
already on base, not this change.
