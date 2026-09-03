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
