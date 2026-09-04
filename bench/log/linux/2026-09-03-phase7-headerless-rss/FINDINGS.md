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

---

## Update 7 (2026-09-04): Phase 7.8 — the six diagnostics, ported

Every diagnostic now answers from the same sources the collector reads. Six
representation-neutral accessors on `Heap` (`diag_chunk` / `diag_payload` /
`diag_user` / `diag_allocated?` / `diag_atomic?` / `diag_flags`) do the one
chunk lookup a bare `BlockHeader*` needs and delegate to `block_payload`,
`user_of`, `block_allocated?` and a new `atomic_of`. A diagnostic that answers
from a different source than the sweep is worse than none — it argues with the
collector about what is live — and under headerless "the header" is the
object's own bytes, so the old reads were reporting whatever the program had
stored there.

Ported: `mark_audit` (20 sites), `invariant` (7, with `counts_live?` gaining a
heap), `heap_dump` (9), `poison_holders` (9, with `scan_block` gaining a heap),
`address_space_audit` (6), `thread_block_audit` (4), `thread_list_tripwire`
(3), and `collect.cr`'s `debug_block_info`, which feeds `segv_report`.

### The bar: purpose-broken gates, both arms, both builds

| gate | header build | `-Dgcry_headerless` |
|---|---|---|
| `mark-audit` | PASS | **PASS** (was: planted arm FAIL) |
| `poison-holders` | PASS | **PASS** (was: planted FAIL, control reported phantom holders) |
| `poison-freed` | PASS | PASS |
| `segv-report` | PASS | **PASS** (was: FAIL both arms — "USED block, size 0" for a FREE one) |
| `thread-block-audit` | PASS | **PASS** (was: hang) |
| `invariants` | PASS | — (spec-driven, header build) |

Each planted arm names what it planted and each control shows the search adds
lines and removes none — "observed red, then green", not "the specs pass".

### Two live bugs found by the port, not by the audits

- **`set_finalizer` / `set_disappearing` wrote into objects.** Both set a flag
  bit through the block header; since 7.4 nothing reads those bits (the
  registry index replaced them), so under headerless every `add_finalizer` and
  every weak-link registration was writing a bit into the object's own first
  words. Both are now no-ops under the flag. `register_disappearing_link` also
  derived its referent with the identity `user_from`, which hands back a large
  object's header slot as the referent; it now uses `user_of`.
- **The nursery was never actually disabled.** Phase 7.3 recorded "headerless
  implies nursery off" as a constraint and then enforced nothing: the
  `property` defaulted to `true` and `GCRY_NURSERY=<n>` switched it on. The
  `thread_block_audit` `lives-minor` arm sets `GCRY_NURSERY=65536` and hung
  inside its own address-space audit for exactly that reason. The default,
  the setter and the env are now all forced off under the flag, and the
  bench's two nursery arms are skipped there with a printed reason — they are
  inapplicable, not failing.

Also caught on the way: one regex over-reach that turned a *chunk* header's
flags into a block accessor (`thread_list_tripwire.cr:335`) — the compiler
refused it, which is the right way for that to fail.

### Standing after 7.8

| | header build | headerless |
|---|---|---|
| spec, 3 configs | 224/224 | — |
| 9 collector gates | all PASS | — |
| 5 diagnostic gates, both arms | all PASS | **all PASS** |
| `property_test` 20 000 / 100 000 | — | PASS / PASS |
| `mt` / `stw_mt` property | PASS | PASS |
| 6 reproducers from the 7.7 hunt | — | all PASS |

What remains of Phase 7 is **7.9, the soak**: both flag arms for a release.

---

## Update 8 (2026-09-04): Phase 7.9 — the soak, in progress

Both arms of `bench/soak.cr` launched detached at 00:29, `--duration=18000`
(5 h), `--rss-limit-kb=4096`, `GCRY_BITMAP_ALLOC=1` on both. Due ~05:30.

Before committing five hours, each arm ran the repo's smoke and a 60 s run:

| | header | headerless |
|---|---|---|
| 10 s smoke | PASS, RSS +1.85 MB / 4 MB ceiling | PASS, RSS +1.35 MB |
| 60 s | PASS, finalized 5935/5935, RSS +1.84 MB, errors=0 | PASS, finalized 5936/5936, RSS +1.86 MB, errors=0 |

The 10 s smoke had shown `finalized=982` of `finalizable=984` on headerless;
at 60 s both arms drain to exactly equal, so that was drain timing at a short
window, not a missed finalizer.

### A number that is not a result

At t≈205 s the soak telemetry showed `pause_p50` 1.79 ms headerless against
13.9 ms header — a 7.8× gap. It is an artefact. The soak reports
`Gcry.pause_stats` p50, which is process-cumulative, and the two arms' early
collections differ enough to skew it for the whole run. The delta'd
per-collection instrument (`gc_phases --live=5000 --survival=0.5`, paired
n=8, both binaries rebuilt from the same source) says:

| | headerless vs header | t |
|---|---|---|
| `pause_per_gc_us` | −0.5% | −1.12 (n.s.) |
| `phase_mark_us` | −1.8% | −0.58 (n.s.) |
| `phase_sweep_us` | **−56.8%** | −8.15 |
| `rss_kb` | −13.1% | −0.51 (n.s. at n=8) |

Pause is identical between builds. The soak's pause columns will not be
compared across arms; its job is the RSS bound and `errors=0` over five hours.

---

## Update 9 (2026-09-04): Kemal end to end — headerless gives the bitmap
## allocator its throughput back

The shipping-bar measurement. Kemal `/json`, `wrk -t4 -c100 -d10s`, paired and
interleaved, both binaries built from the same source, both representations
under `GCRY_BITMAP_ALLOC=1`. **Headerless survived HTTP concurrency**: 0 server
deaths across every run below.

### Headerless vs header, both bitmap

| run | `/json` rps | t | wins |
|---|---|---|---|
| A/B #1, n=9 | **+9.3%** | 2.77 | 8/9 |
| A/B #2, n=9 (independent) | **+6.6%** | 2.24 | 6/9 |

Post-GC RSS: +0.7% (t=0.57) — flat, exactly as the payoff-ceiling analysis
predicted for a heap of ~1 000 live objects, where 16 B per object is 16 KB.

### The placement that matters: three arms, n=7 each

| arm | `/json` rps median | post-GC RSS median |
|---|---|---|
| **headerless (bitmap)** | **39 085** | **13 700 kB** |
| header (default freelist) | 39 024 | 14 328 kB |
| header (bitmap) | 35 869 | 13 636 kB |

Pinned by a direct paired run, headerless vs default, n=9: **+6.8% rps
(t=1.96, borderline)** and **−3.6% RSS (t=−5.11)**.

### What that means

`2026-09-03-simdgc-kemal-e2e` recorded the bitmap allocator as an RSS lever
that **cost 8.3% throughput** on Kemal, and by the plan's own Phase 3 gate did
not clear the bar. With the header removed, that cost is gone: headerless sits
at the default path's throughput (three runs, all positive, t 2.0–2.8 —
"parity or slightly better", not a claimed win) while keeping the bitmap's
RSS advantage. The bitmap allocator's Kemal penalty was, in the end, a
*header-build* penalty.

The plausible mechanism, unmeasured: a 32-byte Crystal object occupies a
32-byte block instead of 48, so the allocation, scan and sweep paths touch
fewer cache lines per object — consistent with `phase_sweep` −57% in the
delta'd instrument.

### The control soak

A 10-minute soak of the `simdgc` PR branch's header build (no Phase 7):
PASS, RSS +2.7 MB, plateau from t≈285 s. Our header arm plateaus too (a step
function from chunk granularity, not a leak) but higher, +6.2 MB against a
4 MB post-drain bound — consistent with 7.2's chunk kinds costing RSS on a
workload that mixes atomic and pointerful allocation, which the soak does.
Headerless does not pay it: +2.0 MB, flat. Whether the header arm's end-of-run
drain recovers enough is what the 5 h run decides.

---

## Update 10 (2026-09-04): the four modes, measured where they differ

### The modes

| mode | how | valid? |
|---|---|---|
| header + freelist | default | yes — the shipping path |
| header + bitmap marks | `GCRY_BITMAP=1` | yes |
| header + bitmap alloc | `GCRY_BITMAP_ALLOC=1` (implies bitmap marks) | yes |
| headerless + bitmap alloc | `-Dgcry_headerless` (compile-time) | yes — forces bitmap alloc on |
| headerless + freelist | — | **impossible by construction**: the freelist threads `next_free` through a header that does not exist; the setter refuses it |

Header/headerless is a compile flag (two binaries); bitmap/freelist is a
runtime knob. Three runtime modes under one binary, one more under the other.

### `bench/micro/gc_phases`, median of 5 (GC duty cycle 22–56% — the instrument that separates them)

**mark-heavy** (300 k live, survival 0.9, shuffled, fan-out 6):

| mode | mark µs | sweep µs | ns/alloc | pause/gc µs | duty % | RSS kB |
|---|---|---|---|---|---|---|
| header + freelist | 9 540 | 3 473 | 77.2 | 9 846 | 24.1 | 50 792 |
| header + bitmap marks | 10 054 | 3 714 | 78.9 | 10 248 | 24.8 | 49 880 |
| header + bitmap alloc | 9 849 | **660** | 86.7 | 10 093 | 22.3 | **36 504** |
| headerless | **25 524** | **155** | 98.8 | **25 870** | **49.8** | 46 528 |

**garbage-heavy** (400 k live, survival 0.05):

| mode | mark µs | sweep µs | ns/alloc | pause/gc µs | duty % | RSS kB |
|---|---|---|---|---|---|---|
| header + freelist | 40 429 | 9 946 | 120.2 | 35 161 | 55.9 | 84 216 |
| header + bitmap marks | 42 532 | 11 078 | 124.2 | 36 312 | 55.7 | 84 084 |
| header + bitmap alloc | 18 276 | 35.7 | 80.1 | 17 833 | 42.2 | 82 788 |
| headerless | 19 325 | **23.2** | **75.3** | 19 054 | 48.1 | **68 188** |

On garbage-heavy, headerless is the best mode on every axis but duty cycle.
On mark-heavy with fan-out 6 it is the worst on mark by 2.6×, and that needed
chasing (below).

### Controlled RSS, 1 000 000 live objects, chain walked in every mode

| mode | 16 B | 64 B |
|---|---|---|
| header + freelist | 36 024 kB | 82 752 kB |
| header + bitmap marks | 36 276 kB | 83 024 kB |
| header + bitmap alloc | 34 996 kB | 81 912 kB |
| **headerless** | **19 184 kB (−46.7%)** | **66 052 kB (−20.2%)** |

The three header modes are within 3% of each other; the header itself is the
whole RSS story.

### The mark-heavy gap: real, reproduced, not yet explained

Headerless scans ~24.7% more objects per collection on that workload (374 019
vs 300 044), constant across survival 0.2–1.0, independent of shuffle, scaling
with the live count. Five controlled probes then failed to reproduce any
difference between modes:

| probe | result |
|---|---|
| fully live graph, 6 random edges each | all modes scan exactly N — **no double-scanning** |
| objects reachable only via raw-buffer edges | all modes keep 100 000/100 000 — **edges followed** |
| stale-edge web, half the roots overwritten, quiescent census | all modes retain exactly 80 729 |
| the same with 300 k / 1 M dropped allocations of churn | still identical |
| `live_objects` counter vs occupancy walk | consistent in both builds |

Two of my own readings were retracted on the way: `occ_live` at census time is
dominated by garbage allocated since the last collection and says nothing about
reclamation (an early "header build fails to reclaim" was wrong), and a probe
whose `old` array was `Pointer.malloc` — GC-managed, hence a root — retained
everything in every mode until rebuilt on `LibC.malloc`.

So the gap is specific to `gc_phases`' multi-cycle dynamics — threshold-
triggered collections mid-allocation, continuous slot overwrite — and does not
appear in any quiescent measurement. It is real for that benchmark and
unattributed. It is not a marking hole in either build.

### Kemal, restated against the matrix

Kemal cannot see any of the mark/sweep columns (duty cycle 0.2–0.5%). What it
does see is allocation and cache density, and there headerless sits at the
default path's throughput (three runs, +6.6 to +9.3% vs header-bitmap, +6.8%
vs default at t=1.96) with −3.6% RSS.

### The 5 h soaks

| arm | verdict | RSS | errors | finalizers |
|---|---|---|---|---|
| **headerless** | **PASSED** | 4 988 → 8 208 kB (+3.2 MB, ceiling +4 MB), flat from ~1 h | 0 | 1 772 781 drained |
| header + bitmap (this branch) | **FAILED the bound** | 5 980 → 10 404 kB (+4.4 MB vs +4.1 ceiling; max 12 428) | 0 | 1 764 609 drained |

The header arm is a step function that plateaued at 12.4 MB and drained to
10.4 — no leak, no errors, 8% over the bound. Whether that overshoot is Phase
7.2's chunk kinds (the soak mixes atomic and pointerful allocation) or already
present on the PR branch is what a 5 h control soak of the `simdgc` branch's
header build, launched at 06:51 and due ~11:51, will decide. Its 10-minute
run plateaued at +2.7 MB.

## Update 11 (2026-09-04): the mark-heavy gap, attributed and closed

The 24.7% extra objects per collection under headerless (Update 10) was never
a marking difference. It was **the collector scanning its own previous cycle's
frames as mutator stack**, and only the representation decided whether what it
found there was accepted.

### How it was found

`gc_phases` copied into a census (`gcp_census2`) that pins the threshold after a
collection, so the retained set can be attributed with `GCRY_LIVE_ATTR=1`
first-mark counters. Same workload as Update 10 (`--shuffle --fanout=6
--survival=0.25`, 200 k ring):

| build | stack first-marks | heap first-marks | non-ring objects held by other non-ring objects |
|---|---|---|---|
| header | 11 | 200 024 | 0 |
| headerless | 56 | 249 660 | 49 692 |
| headerless, `GCRY_TYPE_ID_GATE=1` | 8 | 200 027 | 0 |

Forty-five extra stack seeds, each a *dead ring object* (fanout words still
pointing at other dead ring objects), retain a 50 k-object web. The type-id
gate erases the gap because those seeds have no type id — but the gate is off
by default because it rejects raw buffers, so it is a confirmation, not a fix.

A `-Dgcry_hl_assert` dump that prints the **stack slot** of every accepted seed
placed all of them in one region: 8.6–9.2 KB *above* the SP recorded at
collection entry, and 0.6–1.3 KB *below* the SP at `GC.malloc` entry. That is
inside gcry's own allocation-to-collection chain — eight frames spanning
9.9 KB, because `run_collection` had the entire mark phase inlined into one
~9 KB frame. The SP was captured *inside* that frame, so the frame itself sat
above the captured SP; the previous cycle's mark batches survived in it, were
re-established at the same address by the next cycle (same call path), and
were scanned as mutator stack before that cycle overwrote them.

The header build had exactly the same residue. Its values were block-start
addresses, which under a header are `user − 16`, so `base_only` rejected every
one. Headerless makes block start and user pointer the same address, and
`base_only` accepted them. The regression was representation luck running out.

### The fix

- `run_collection` is now a thin wrapper that records the entry SP and calls a
  `@[NoInline]` body, so every frame a collection pushes lies *below* the
  recorded SP.
- `GCRY_COLLECT_SCRUB` (default 16 384 bytes, 0 disables) zeroes the dead stack
  below that SP at collection entry and again at exit, through the existing
  `clear_stack` primitive (red zone and memset-callee margin respected; fiber
  stacks now use their own bounds instead of a 512 B cap). Two memsets per
  collection; not measurable against a millisecond mark.

| build, after | stack first-marks | heap first-marks | web |
|---|---|---|---|
| headerless, scrub on (default) | 10 | 200 024 | 44 |
| headerless, `GCRY_COLLECT_SCRUB=0` | 56 | 249 662 | 49 694 |
| header, scrub on | 10 | 200 025 | 0 |
| header, scrub off | 11 | 200 024 | 0 |

The knob-off row reproduces the regression on demand; the header build is
unchanged either way. Timing on `gc_phases` itself follows below.

### `gc_phases` after the fix (`--shuffle --fanout=6 --survival=0.25`, 3 s, three interleaved runs per arm)

| arm | `phase_mark` ms | pause per GC ms | ns/alloc | RSS MB |
|---|---|---|---|---|
| headerless, scrub on (default) | 10.1 / 10.8 / 10.9 | 11.4 | 59.3 | 52.6 |
| headerless, `GCRY_COLLECT_SCRUB=0` | 21.3 / 21.0 / 21.5 | 22.0 | 80.1 | 58.7 |
| header + `GCRY_BITMAP_ALLOC=1` | 9.8 / 9.7 / 9.5 | 10.4 | 61.6 | 64.0 |
| header, default (freelist) | 19.7 / 20.4 / 19.7 | 20.8 | 89.1 | 68.7 |

The knob-off arm reproduces the Update 10 gap on demand (2× mark, +35% per
allocation, +12% RSS from the retained web). With the scrub on, headerless
marks within ~10% of the header bitmap arm, allocates 4% cheaper, and holds
18% less RSS. The remaining ~1 ms of mark is the per-object chunk-kind lookup
headerless pays where the header build reads a flag it already loaded; it is
not stack residue (the census is identical to the header build's).

The header build's default freelist arm is 2× the bitmap arm on mark in both
the before and after tables; that is the header walk, not this change.

### Gates for this update

knob-doc-check, lint, dormant-flush-race, page-release-corruption,
heap-counters, find-block-race, parallel-mark-process, mark-audit: green.
property_test (20 000 iterations), mt-property and stw-mt (short) green under
headerless; the header build's short suites green.

`make live-graph-audit` fails its own self-check ("HOLED released N B against a
control — the walk did not run"): the HOLED arm must release at least 4x the
no-walk control and does not. Built and run from this branch's tip and from
`master` in clean worktrees, it fails identically (control 12.2 / 15.9 MB,
HOLED 43.8 / 49.6 MB), and disabling the new scrub does not move it (17.3 /
50.4 MB). Pre-existing; not attributed here.

The spec suite had never been run under `-Dgcry_headerless`: 29 failures and
one error, all examples asserting header-build facts. Guarded with reasons or
rewritten against the chunk-aware accessors; `json_live_attr` was reading block
sizes from the header (zero under headerless) and is ported.


### Kemal, the regression guard

Headerless `/json`, `GCRY_BITMAP_ALLOC=1`, same binary, seven interleaved
pairs of scrub on (default) vs `GCRY_COLLECT_SCRUB=0`: 41 265 vs 41 057 req/s
median, paired difference +0.64% at t = 0.12 — flat, as two memsets per
collection at a 0.2–0.5% duty cycle should be. Post-collect RSS 13.8 MB in
both arms.

## Update 12 (2026-09-04): the reviewer's pass

Every remaining item on the plan's verification list ran green: invariants,
spec-process, stw-index-race, poison-freed, oom-no-hang, stw-watchdog, asan,
and soak-smoke in both builds (header +584 kB over the run, headerless
+1292 kB, ceiling +4096 kB). The one message asan printed mid-run,
`live_objects mismatch: actual=1 reported=2`, is the invariants spec proving
its own detector fires.

### Found and fixed

- **Large objects were scanned to the end of their mapping, not to their
  size.** Removing `clamped_scan_size` for the review finding replaced
  `min(header.size, extent)` with the extent for large blocks. The header
  keeps the size in both builds, so `block_payload` now returns it, clamped
  to the mapping. Effects that were real: `diag_payload` and live attribution
  reported a large object's mapping size, and the precise-layout `size_match`
  could never hit for a large object. The stale-tail retention I expected
  from a cached mapping did *not* reproduce (the tail example passes with
  the fix reverted, for a reason I did not run down); the spec keeps both
  properties pinned.
- **Live attribution under headerless counted zero bytes.** `json_live_attr`
  and `note_first_mark` read sizes and the atomic flag from the header;
  both now go through the chunk.
- **The collect scrub was inflating `clear_stack_calls`**, a metric that
  means the allocation-path wipe. It has its own counters
  (`collect_scrub_runs`, `collect_scrub_bytes_total`, on `/metrics` and
  `json_stats`), and the stack-scrub spec is back to its original meaning.

### Specs

The headerless guards were reviewed one by one. Where the property survives
the representation it is now asserted in both builds, and in the header build
on both allocators: block reuse after `free` (freelist LIFO vs bitmap
lowest-free-bit, within one chunk of allocations), `malloc` re-zeroing a
reused block, `malloc_atomic` not clearing one, the TLAB examples' allocation
and free checks. What headerless refuses — the nursery, turning the bitmaps
off — has its own headerless-only examples, together with the large-object
layout (header behind the object, `contains?` from the header slot). The
remaining guards are features that are off by design there: nursery, TLAB
refill counters, the mprotect barrier, the geometry's bitmaps-off branch.

One behaviour worth knowing, found by the rewritten reuse examples: under the
bitmap allocator with the nursery on, an explicitly freed block in a nursery
chunk is not handed out again until the next minor collection (the pool
cursor skips nursery chunks). The freelist build reuses it immediately. The
examples run with the nursery off and say why.

### The adversarial reviewer's findings (same day)

A second reviewer (a subagent told to reproduce before reporting) found four
bugs in the headerless paths, each with a probe, all fixed and pinned:

1. **`free` read a large object's first bytes as its header** under
   headerless (`from_user` is the object there), so a live large object
   whose byte 4 was odd raised "double free" and a real double free went
   undetected and decremented `live_objects` twice. `free` now resolves the
   chunk first and takes `large_header` for a large chunk.
   `spec/heap_spec.cr` "frees a large object whatever its first bytes hold".
2. **Large atomic objects were scanned** under headerless: the mark path
   tested the chunk's ATOMIC flag (never set for large chunks) or the
   header's (compile-time false). Every large String and IO buffer was
   conservatively scanned — the false-retention shape this file spent a day
   on. `atomic_of` was already right and is now used. `spec/large_scan_bounds_spec.cr`
   "does not scan a large atomic object".
3. **`realloc` dropped atomicity** for the same reason; same fix, pinned.
4. **`freelist_reserve_fully_dead` still ran on bitmap chunks** from the
   sweep's second empty-chunk branch (bounded-excess path under Parallel),
   double-booking free bytes past the heap's capacity and, under headerless,
   writing headers into objects. The guard now lives in the function.

And one race it could not reproduce but argued correctly: the post-STW
dormant flush walks chunks and DONTNEEDs their pages without a lock, and a
mutator could revive a chunk and allocate into it between the flag read and
the madvise — silently zeroed objects on a bitmap chunk. Both revive paths
now take the alloc lock to check the live-walk flag and flip dormant off, so
a revive is ordered strictly before or after the whole walk; a refused
revive maps a fresh chunk. `dormant_revive_during_flush` now counts refusals.

It also answered why the stale-tail example passed with the fix reverted:
the pointer was stored at offset 299 500, which is not word-aligned, so the
word scan could never read it. The example now stores at 299 504 and fails
without the clamp.

### `make dormant-flush-race`: a pre-existing lost root, now easier to hit

The gate went red after the reviewer's fixes, and the bisect says the fixes
are not the cause. Its queued arm refuses a worker's `GC.free` of a 40 KiB
block it allocated and verified moments earlier, with the header already
FREE and the chunk on the release queue: the sweep took a live large block
for dead. The harness's own note (master, 2026-08-29) records this at
"about once in ninety children". Runs of the queued arm, six children each:

| tree | failed children |
|---|---|
| `master`, 3 runs | 1 of 18 |
| `efb48f1` (yesterday's tip), 2 runs | 2 of 12 |
| `c578ca5`, 2 runs | 2 of 12 |
| working tree (this update), 3 runs | 5 of 18 |

The branch marks twice as fast, the harness's collector thread collects in a
loop, and the race is per collection, so the exposure roughly doubles; the
first two runs of the day were 0 of 6 and 0 of 6, which is why the morning
gate battery was green.

Excluded by reading: the allocation-time STW windows in `alloc_large`
(`map_chunk`, `set_used_large`, allocate-black) all run under the allocation
lock that the after-world sweep also takes per large chunk; the suspend
handler copies the ucontext registers into a table the scan reads, so a
pointer held only in a callee-saved register is covered. Not attributed here.
Open, and older than the branch.

## Update 13 (2026-09-04): both release walks made sound; `live-graph-audit` green

### The gate was measuring the wrong thing, and then it found a real bug

`make live-graph-audit` demanded that each walk arm release at least 4x the
no-walk control, by the aggregate `dontneed` counter. The control still runs
the dormant flush, which grew on master until the ratio was 3.1x, so the gate
was red for a reason unrelated to the walks. It now reads each walk's own
counter (`page_release_bytes`, new, for the HOLED walk; `mostly_empty_bytes`
for the sparse walk), requires it above 8 MiB per arm, and requires the
control's to be 0 — direct evidence the walk ran and the control did not.

With that fixed, the third run failed a HOLED child for real. The knob had
said so all along: `GCRY_PAGE_DONTNEED=1` was documented as "known to zero
live objects, research only" (`make page-release-corruption`: 4 of 28).

### The mechanism, and the fix

The post-STW walk unlinks a chunk's free-only page runs from the class
freelist under the freelist lock, then computes the live mask from block
headers and issues `madvise` *without* the lock. TLAB batches hold blocks
that are FREE-headed and off the global freelist, so the unlink cannot reach
them and the mask calls their pages free; a block handed out and written
between the mask and the syscall is zeroed afterwards.

Fix: `with_small_allocation_excluded` (tlab.cr) holds every TLAB slot lock
and allocation-batch slot lock, then the class freelist lock — every lock a
small allocation of the class can take, in the order the TLAB refill path
already establishes — and the unlink, the mask, and the syscall now all sit
inside it. Only the opt-in walks pay; the default path is unchanged.

| gate | before | after |
|---|---|---|
| `live-graph-audit`, HOLED arm | 1 of 18 children | 0 of 30 (5 runs) |
| `live-graph-audit`, sparse arm | 0 of 18 | 0 of 30 |
| `page-release-corruption`, DONTNEED arm | 4 of 28 (recorded) | 0 of 12 (3 runs) |

The knob's warning is rewritten: opt-in for throughput and RSS, not for
soundness. It stays opt-in.
