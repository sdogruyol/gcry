# Phase 7.7 — the payoff, measured: up to −44.8% RSS on small objects

Date: 2026-09-03 · host: WSL2 · branch `simdgc-headerless` · `-Dgcry_headerless`
1 000 000 live 16-byte-chained objects, rooted from the stack, collected, then
the whole chain walked to prove every link survived. No arrays and no large
allocations, so this isolates the case the phase exists for.

## Result

| object | header build | headerless | saving | theory `16/(16+n)` | chain intact |
|---|---|---|---|---|---|
| **16 B** | 35 008 kB | **19 312 kB** | **−44.8%** | 50% | both ✓ |
| 32 B | 50 804 kB | 35 028 kB | −31.1% | 33% | both ✓ |
| 64 B | 81 736 kB | 66 248 kB | −18.9% | 20% | both ✓ |
| 128 B | 144 472 kB | 128 864 kB | −10.8% | 11% | both ✓ |

At 1.5 M × 16 B the saving is **50 792 → 27 400 kB, −46.1%**.

Every measured value tracks `16/(16+payload)` and sits just under it, which is
the bitmaps: halving `block_bytes` doubles the blocks per chunk and so doubles
`occ` and `mark`. The model is confirmed, including its second-order term.

**Correctness holds where it was measured.** All 1 000 000 (and 1 500 000) chain
links survived collection in the headerless build. Marking, sweeping and
allocation are all working on small objects with no per-block header at all.

## What this does not yet say — the build is partial

Headerless works for **small objects only**. `bench/micro/gc_phases` still
crashes under it, and the reason is structural rather than a loose end:

**Large objects keep their metadata in the block header.** `cache_large_chunk`,
`@pending_large_cache` and the large freelists all chain large blocks through
`header.value.next_free`, and `sweep_large` *writes* that link. With no header
those writes land on the object's own bytes — and a Crystal `Array`'s buffer is
a large object, which is why anything holding an array corrupted immediately.

Partly addressed here: large chunks now reserve a real header **inside the
metadata region** (`ChunkHeader.large_header` / `large_user` /
`large_data_offset`), so the object and its header no longer overlap, and
`set_used_large` writes it where the small-block `set_used` is a no-op. That
fixed the small-live-count cases. The rest of the large path — roughly 40 sites
across `heap.cr` and `collect_sweep.cr` — still assumes `data_start` is a header
and a user pointer is `header + 16`, and each fix has revealed another.

## The ledger, now that both sides are measured

| | 16 B-dense | 64 B-dense | Kemal |
|---|---|---|---|
| **payoff** | **−44.8% RSS** | −18.9% RSS | ~0.1% |
| 7.2 chunk kinds | +7.9% RSS (mixed-kind only) | same | +7.9% |
| 7.4 finalizer index | +9.5% free path | same | same |
| 7.6 size from chunk | +7.1% `phase_mark` | same | same |

For a small-object-dense heap the payoff is **five to six times** the RSS it
costs, and it dwarfs the two throughput costs. For Kemal it remains a clear
loss. The phase is a real win, on a workload gcry does not currently ship
against — which is exactly what the payoff-ceiling FINDINGS predicted, now
confirmed by measurement rather than arithmetic.

## Standing

`-Dgcry_headerless` is an **incomplete, experimental build**. It must not be
used for anything holding a large object. The header build is unaffected and
fully gated (spec 222/222, invariants, mark-audit, property, mt-property,
stw-mt-property, ameba, format all green).

Remaining to finish the phase: relocate large-object metadata into the chunk
(the ~40 sites), then port the six diagnostics with their purpose-broken gates
observed red.

---

## Update: the large-object path, eight bugs later

Continuing 7.7 into the large-object path. Large objects keep a real header —
reserved inside the chunk's metadata region — because they need somewhere for
the freelist and pending-cache links. Small blocks are the ones that lose theirs.

Fixed this round, each found by tracing a specific corruption rather than by
inspection:

1. `alloc_large` sized the mapping by `ChunkHeader::SIZE + BlockHeader::SIZE`,
   16 bytes short of the new data offset — the object's tail fell outside the
   mapping. Now `ChunkHeader.large_data_offset`, one definition for sizing,
   carving and the header slot.
2. `set_used` is a no-op under headerless (a small block has nowhere to write),
   which silently dropped every large block's size and LARGE flag →
   `set_used_large`.
3. `BlockHeader.large?` answered from the block, so a small object could be
   routed into the large free path and `cache_large_chunk`'d onto a size-class
   chunk. `free` now asks the chunk.
4. `free` derived the header via the generic `from_user` (identity under
   headerless), so it cached the *user* pointer as a header.
5. `owns_user_pointer?` round-tripped through `user_from`, so `GC.free` on a
   large object reported "not a live gcry allocation".
6. The large freelist walkers (`cache_large_chunk`, `take_large_free`,
   `trim_large_cache`, `flush_pending_large_cache`,
   `release_large_freelist_pages_locked`) chain blocks through
   `from_user`/`user_from` → `large_header_from_user` / `large_user_from_header`.
7. `scan_object` and `block_payload` derived the object address with
   `user_from`, so a large object was scanned from 16 bytes early and 16 bytes
   past its mapping — a SIGSEGV in mark. Now `Heap#user_of(chunk, header)`.
8. **The one that mattered most:** large chunks are not bitmap chunks, so every
   mark accessor fell back to `BlockHeader.set_mark` / `marked?` — which are
   no-ops under headerless. Large objects could therefore *never be marked*, and
   were swept while live on the first collection. Fixed with `set_mark_large` /
   `marked_large?` / `clear_mark_large`, routed through `hdr_set_mark` /
   `hdr_marked?`.

After all eight, a rooted large object survives collection, is found by
`is_heap_ptr` and reports `live?` — where before it was unmapped and read back
as a SIGSEGV.

### What is still wrong

**Two bytes at `user+4` are overwritten during collection**, with `0x0001`. The
data is verified intact immediately before `GC.collect` and corrupt immediately
after, so the collector writes it. It is *not* a mark write: an assertion built
into `hdr_set_mark` / `heap_clear_mark` (`-Dgcry_hl_assert`) that fires when
either is handed an address other than the chunk's header slot never triggers.
A 2-byte write of 1 at `+4` has the shape of a `flags` field being set to FREE,
but every full-struct writer would have disturbed the surrounding bytes and
those are intact.

So `-Dgcry_headerless` remains **experimental and unsafe for large objects**,
and `bench/micro/gc_phases` still cannot run under it.

### The small-object result is unaffected and reconfirmed

1 000 000 × 16 B, all 1 000 000 chain links intact, **rss 19 320 kB against
35 008 kB** for the header build — **−44.8%**, the same number as before the
large-object work. The header build stays fully gated: spec 222/222 across
default / `GCRY_BITMAP_ALLOC` / `GCRY_CHUNK_RADIX`, invariants, mark-audit,
property, mt-property, stw-mt-property, parallel-mark-process, ameba, format.

---

## Update 2: the large-object path works, and the root cause was one line

The 2-byte corruption at `user+4` is fixed, and the cause was not any of the
places the reasoning kept pointing at.

`map_chunk` **hardcoded** `data_offset = ChunkHeader::SIZE` for large chunks and
only called `chunk_geometry` for size-class chunks:

```
bitmap_words = 0_u32
data_offset  = ChunkHeader::SIZE.to_u32
if @bitmap_marks && size_class != UInt32::MAX && ...
```

So the reserved-header-slot geometry added in the previous commit never applied
to a single large chunk. The header slot and the object were therefore at the
*same address*, and the first `set_mark_large` wrote the mark generation into the
object's second word — two bytes at `user+4`, exactly the observed damage.

It was found with an in-code watchpoint rather than by reading: an address range
a test declares off-limits (`BlockHeader.hl_guard`, compiled in under
`-Dgcry_hl_assert`), checked by every large-mark write, which printed the
offending backtrace on the first hit. No debugger is available on this host and
the arithmetic alone had pointed at three innocent functions.

A second conflation fell out of the fix and was caught by
`spec/bitmap_marks_spec.cr`: `large_data_offset` is the chunk-to-**object**
distance (48 in both builds, and what sizes the mapping), while the chunk's
`data_offset` **field** is where its *data* begins — 32 with headers in front
(where `data_start` *is* the header) and 48 under headerless. Using one for the
other broke the header build, which is precisely what that spec exists to catch.

Also fixed: three more large-chain walkers (`release_large_chain`,
`queue_large_release`, one in `collect.cr`) still converting with the generic
`from_user`, and `realloc`, which read `old_size` and atomicity from the block —
garbage under headerless, and the length of a `memcpy`. `realloc` now takes size
from the chunk for small blocks and from the header for large, because a large
block's header holds the size actually requested while `block_payload` gives the
mapping extent, an upper bound that would copy past the object.

## Where the headerless build now stands

| test | result |
|---|---|
| `property_test` (to 10 000 iterations) | **PASS** |
| `mt_property_test` | **PASS** |
| `stw_mt_property_test` | **PASS** |
| `bench/micro/gc_phases`, every size | **PASS** |
| allocation overlap probe | **PASS** |
| `property_test` at 30 000+ iterations | **FAIL** — accumulating |

RSS, controlled (fixed 1 000 000 live objects, whole chain walked to prove every
link survived in both builds):

| object | header | headerless | measured | theory `16/(16+n)` |
|---|---|---|---|---|
| **16 B** | 34 888 kB | **19 320 kB** | **−44.6%** | 50% |
| 32 B | 50 660 kB | 35 032 kB | −30.8% | 33% |
| 64 B | 81 716 kB | 66 180 kB | −19.0% | 20% |
| 128 B | 144 492 kB | 128 724 kB | −10.9% | 11% |

Every size within ~5% of theory, the gap being the doubled bitmaps.

**Do not measure this on `gc_phases`.** It allocates for a fixed *wall time*, so
the two builds do different amounts of work and settle at different heap sizes;
it reported −73.7% for 128 B objects, where removing a 16-byte header can save
at most 11%. The controlled probe is the honest instrument.

## What is left

One accumulating bug: `property_test` survives 10 000 iterations and fails
somewhere before 30 000. Rare or cumulative rather than systematic — the shape of
a slow leak or a cache that drifts, not a wrong pointer computation, which would
fail immediately.

The header build is unaffected throughout and fully green: spec 222/222 across
default / `GCRY_BITMAP_ALLOC` / `GCRY_CHUNK_RADIX`, plus invariants, mark-audit,
property, mt-property, stw-mt-property, parallel-mark-process,
page-release-corruption, heap-counters, find-block-race, ameba and format.

---

## Update 3: the "accumulating corruption" was not corruption

Chasing the failure that appeared between 10 000 and 15 000 `property_test`
iterations. Running it under `GCRY_DEBUG_INVARIANTS=1` produced the line the
release build had been unable to print:

```
property test ok seed=1 iterations=15000 collects=6404 verifies=6403
                 freed=6271 peak_nodes=6469 warnings=0
Unhandled exception: pthread_join: No such process (RuntimeError)
  from src/gcry/parallel_mark.cr:102 in 'shutdown_mark_workers'
  from src/gcry/heap.cr:331 in 'destroy'
```

**The test passes.** Every root verified, zero warnings, 6 404 collections. The
process then dies in `Heap#destroy`, joining a mark-worker `Thread` whose handle
is stale. Reproducible 3/3 headerless, 0/3 on the header build, and it still
happens with `GCRY_PARALLEL_MARK=1`.

The earlier reading — "accumulating heap corruption" — was wrong, and wrong for
an avoidable reason: the release build's failure message is itself built by
string interpolation, and the process was dying before flushing it, so the only
evidence was a blank line and a SIGSEGV in teardown. Reaching for the diagnostic
build first would have cost one run and saved several.

### What was ruled out on the way, each by measurement

- **Magic reciprocal.** Headerless changes every `block_bytes`, so the exactness
  bounds the plan verified for `16 + payload` do not carry over. Recomputed for
  all 40 classes at `payload`: tightest first divergence is **51 MiB**, against a
  128 KiB chunk. Safe, with a 400x margin.
- **Allocation bounds.** 120 000 allocations across six size classes, every one
  inside its chunk's `data_start..data_end`. The doubled block count per chunk
  does not overrun the tail mask.
- **Object-graph survival.** An object holding an `Array` of objects — the exact
  shape of `Heap#@mark_worker_threads` — through 200 000 allocations and repeated
  collections: all 20 children intact, tags unchanged.
- **Heap-object integrity.** A canary in a `Heap` field across 30 000
  alloc/collect iterations: unclobbered.
- **Chunk release** (`GCRY_KEEP_CHUNKS=1`) and **page release** (already stood
  down on bitmap chunks): neither is involved.

### One real bug found and fixed on the way

`cache_large_chunk`'s double-insert guard is `if BlockHeader.free?(header)`,
which answers `false` unconditionally under headerless — so the guard never
fired. Its own comment says what that costs: one chunk in a bucket chain twice,
and "`take_large_free` then hands the same memory to two owners while
`trim_large_cache` is still free to unmap it under both". Fixed with
`free_large?`, which reads the flag a large block genuinely has. It was not the
cause of this failure, but it was a live double-free waiting for the right
timing.

### Standing

Headerless correctness now has real evidence behind it rather than absence of
crashes:

| check | result |
|---|---|
| `property_test`, 15 000 iterations | **PASS**, warnings=0 |
| `mt_property_test` | **PASS** |
| `stw_mt_property_test` | **PASS** |
| object-graph survival, 200 000 allocs | **PASS** |
| allocation overlap, 20 000 allocs | **PASS** |
| allocation bounds, 120 000 allocs | **PASS** |
| `gc_phases`, every size | **PASS** |
| `Heap#destroy` teardown | **FAIL** — stale mark-worker thread handle |

The remaining defect is in **teardown**, not in the collector: the heap is
correct for its whole life and dies while shutting its mark workers down. That
is a much smaller and better-understood problem than the one this update
started with.

---

## Update 4: the residual bug, narrowed but not closed

The `pthread_join` failure was a symptom, not the defect. Instrumenting what
`shutdown_mark_workers` actually sees (`Heap#mark_worker_pool_state`, added as a
permanent diagnostic) shows `threads=0 pthreads=0 workers=1` at 5 000, 8 000 and
11 000 iterations — the bookkeeping is **correct**, so the join error at 15 000
was corruption reaching that field, not a worker-lifecycle bug.

Release and debug builds fail differently — release segfaults mid-run on a
corrupted call target, debug completes the test and dies in teardown — which is
the signature of layout-sensitive memory corruption rather than a logic error.

### Ruled out this round, each by a dedicated probe

| hypothesis | probe | result |
|---|---|---|
| magic reciprocal wrong for headerless `block_bytes` | all 40 classes recomputed | safe to **51 MiB** vs a 128 KiB chunk |
| allocations overrun the chunk | 120 000 allocs, six classes | all in bounds |
| object graphs not traced | `Array`-of-objects through 200 000 allocs | all intact |
| `Heap` object clobbered | canary field, 30 000 iterations | intact |
| `realloc` / Array churn | 200 000 grow+dup+verify rounds | clean |
| mark-worker lifecycle | pool state at 5/8/11 k iterations | correct |
| page release | already stood down on bitmap chunks | not involved |

### What is left, and the one real lead

`GCRY_KEEP_CHUNKS=1` (empty-chunk release off) makes 15 000 iterations pass
where the default fails — but it still fails at 30 000. So **chunk release
aggravates the defect without being its cause**; it widens a window rather than
opening it.

The failure needs >11 000 property_test iterations to appear, survives every
targeted probe above, and is sensitive to build layout. That profile points at a
rare interleaving in chunk lifecycle — reclaim, revive, or release — rather than
at any of the pointer-arithmetic changes this phase made, all of which would
fail immediately and deterministically.

### Honest standing

`-Dgcry_headerless` is **not correct** and must not be used. It is much closer
than it was: it now passes `property_test` to 11 000 iterations,
`mt_property_test`, `stw_mt_property_test`, `gc_phases` at every size, and four
purpose-built probes, and it delivers the **−44.6% RSS** the phase exists for.
But "passes a lot of tests" is not "correct", and the remaining defect is real.

The header build is unaffected and fully gated throughout.

---

## Update 5: a dependency enforced, and the bug still open

Two more hypotheses tested and rejected, and one piece of hardening that should
have been there from the start.

**Enforced: headerless requires the bitmap representation.** The freelist
allocator threads `next_free` *through the block header*, and a headerless small
block has none — so every freelist push writes a link into the object's own first
words. `Heap#initialize` now forces `bitmap_alloc` and `bitmap_marks` on under
`-Dgcry_headerless`, and the `bitmap_alloc=` setter refuses to turn them off.
Previously a heap constructed without the env var would corrupt silently.

This was *not* the cause of the failure being chased — `Gcry::Heap.new` already
reads `GCRY_BITMAP_ALLOC` from the environment, so the tests were running with it
on. It is kept because the dependency is real and was undefended, and because a
future caller constructing a heap directly would have hit it.

**Rejected by measurement:** the nursery (off by default, and forcing it either
way changes nothing), `MADV_DONTNEED` (`GCRY_DISABLE_MADVISE=1`), mostly-empty
reclaim (`GCRY_MOSTLY_EMPTY=0`), and lazy sweep (both directions). None of them
moves the failure.

### Where the hunt stands

The failure is stubbornly reproducible at 20 000 `property_test` iterations and
absent at 11 000, which is deterministic enough to argue *against* a race and
for a threshold — something that accumulates until it crosses a boundary. Chunk
release widens the window (`GCRY_KEEP_CHUNKS=1` survives 15 000 but not 30 000)
without being the cause.

Everything cheap has now been eliminated. What remains is the expensive kind of
work this needs and has not had: a bisect on the operation sequence itself
(`property_test` writes an op log — replaying a failing seed and shrinking it is
the obvious next move), or a poisoned-freed build that traps the first read of a
reclaimed block rather than waiting for the damage to surface thousands of
operations later.

### Standing, unchanged in substance

`-Dgcry_headerless` is **not correct**. It delivers **−44.6% RSS** and passes a
wide battery — `property_test` to 11 000 iterations, `mt_property_test`,
`stw_mt_property_test`, `gc_phases` at every size, object-graph survival,
allocation overlap, allocation bounds, realloc/Array churn — and none of that
makes it correct. The header build is unaffected and fully gated.

---

## Update 6: root cause — one containment predicate

The "accumulating, layout-sensitive, seed-independent" failure was a single
line, and it had been in front of the whole hunt:

```crystal
def self.contains?(chunk, addr)
  start = data_start(chunk).address      # <- here
  addr >= start && addr < finish
end
```

`scan_object` looks a large object's chunk up **by its header address**. Under
headerless a large block's header is reserved *before* `data_start`
(`chunk+32` versus `chunk+48`), so `contains?` said no, `chunk_containing`
returned nil, and `scan_object` took its `return unless chunk` exit — **large
objects were never scanned at all**. Everything a large object referenced was
reclaimed on the next cycle. With headers in front the header *is*
`data_start`, so the header build never saw it.

That one predicate explains every symptom of the last several rounds:

| symptom | mechanism |
|---|---|
| `pthread_join: No such process` in `Heap#destroy` | `Gcry::Heap` is a 518 KB large object; its `@mark_worker_threads` Array (offset 529 920) was reclaimed and reused |
| `@mark_stack.push` writing to address 0 | its `MarkStack` (offset 530 152) was reclaimed, `finalize` munmapped and nulled `@base` |
| "accumulating", >11 000 iterations | it took that long for `property_test`'s live set to need a large `Array` copy whose loss mattered |
| seed-independent | every seed reaches that point at about the same iteration |
| release vs debug fail differently | which reclaimed block got reused first |
| `KEEP_CHUNKS` delays but does not cure | fewer reuses of freed blocks, same unscanned parents |

### How it was found

Not by reading — the arithmetic had accused three innocent functions. It fell
out of narrowing the reproducer until the shape was undeniable:

1. `Gcry::Heap.new` held across default-heap churn dies within 4 collections.
2. `instance_sizeof(Gcry::Heap)` is **530 312** — a large object — and every
   reference field sits in its last 400 bytes.
3. A synthetic 64 KB parent loses a finalizer-bearing child (a finalizer run on
   a live object is unambiguous), while a **small** parent with the same child
   does not. Large parents are not scanned.
4. `scan_object`'s first act on a large header is `chunk_containing`; its
   predicate starts at `data_start`; under headerless the header is below it.

Two earlier "survivals" were artefacts worth naming: children whose pointers
the compiler kept in registers across `GC.collect` were stack roots in
disguise, and a probe that held all children in a Crystal `Array` rooted them
through the array. Both made a fully-unscanned parent look partially scanned,
which is what sent the hunt toward type- and position-based hypotheses. The
finalizer-run detector was the first that could not be fooled that way.

### Fix

`contains?` starts at the block header for a large chunk and at `data_start`
for a small one — identical to before with headers in front, and correct under
headerless. Small-chunk metadata still does not resolve, which
`spec/large_contains_spec.cr` pins alongside the large case.

### Result

| check | before | after |
|---|---|---|
| `property_test` 100 000 iterations | dies ~12 000, every seed | **PASS, warnings=0** |
| `mt_property_test` / `stw_mt_property_test` | pass | pass |
| `gc_phases`, every size, with and without radix | pass | pass |
| eight targeted reproducers from this hunt | 5 fail | **all pass** |
| RSS, 1 M × 16 B, chain walked | — | **−44.5%** (32 B −31.2%, 64 B −19.2%, 128 B −10.8%) |

`mark_audit` still fails under headerless: it is a **diagnostic** with twelve
direct header reads of its own, and porting the six diagnostics is Phase 7.8,
not a collector defect.

### Standing

`-Dgcry_headerless` now passes every collector correctness check this project
has, at full length, plus eight reproducers built during the hunt. The header
build is unaffected and fully green. What remains of Phase 7 is 7.8 — port the
six diagnostics with their purpose-broken gates observed red — and 7.9, the
soak.
