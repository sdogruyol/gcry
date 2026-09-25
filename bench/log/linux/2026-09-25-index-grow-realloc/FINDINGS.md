# Chunk index growth handed a stopped-world collector freed memory

**Date:** 2026-09-25 · host: Linux 7.0.0-31-generic x86_64 (QEMU, 12 vCPU),
glibc 2.43, Crystal 1.21.0 · `bench/index_grow_race.cr`

## The defect

`index_ensure_cap` grew `@chunk_index` with

    ptr = LibC.realloc(@chunk_index, bytes)   # moves: frees the old array
    @chunk_index = ptr                        # published only now

and `chunk_containing` / `bitmap_indexed_chunk` read `@chunk_index`
**unlocked** while the world is stopped, because a mutator frozen holding
`@index_lock` would otherwise wedge the collector. A mutator suspended between
those two lines left the whole collection reading a freed block. glibc
rewrites a freed block's first words: for a tcache-sized one (an index of up
to 128 chunks) the safe-linked `next` (`block >> 12` when the bin was empty)
and the tcache key; for a larger one the bin's `fd`/`bk` into the arena. So the
entries for the two lowest-addressed chunks were garbage for that collection:

* roots in those chunks were not found, their objects were not marked, and the
  sweep reclaimed them live;
* a lookup that dereferenced a garbage entry faulted at `block >> 12` plus a
  field offset — an address in no mapping.

Every layout: it is `map_chunk → index_insert → index_ensure_cap`. The window
is two instructions wide and opens only when the index doubles (16, 32, 64
chunks …), and `realloc` frees nothing when it can grow in place, so it was
rare.

## What it explains

| sighting | shape | now |
|---|---|---|
| `stw_mt_property_test --tlab`, local campaign 2026-09-25 | 13 pinned live objects DEAD in one chunk, ~1 run in 900 | roots not found through the stale index |
| `make thread-churn-uaf`, CI 2026-09-19 / 2026-09-22 | SIGSEGV at `0x55816aff0` / `0x55797df8d`, "outside the heap span" | a lookup through a freed tcache block's link, `block >> 12` |

The harness reproduces both, on demand, at 50 ms:

    gcry: SIGSEGV at 0x597883efb — outside gcry's heap span [...]
    gcry: SIGSEGV at 0x64bce7a55 — outside gcry's heap span [...]
    gcry: no mapping holds that address, but 0x64bce7a55 << 12 = 0x64bce7a55000
          is in the writable mapping [0x64bce7a3e000, 0x64bce7a5f000)
    gcry: that is glibc safe-linking — [...]

(the brk heap beside the executable, the CI sightings' shape), and with the
growing thread's own arena at `0x7186c0000000`: `0x7186c0011`, `0x7046a8011`,
`0x7fdc6c011`. With the payload still intact, a lost root reads
`heap_ptr=true … free: true … cookie=true`: reclaimed while pinned, i.e. not
marked.

## How it was found

The campaign's DEAD roots said "chunk-level", not "block-level" (13 contiguous
blocks), and two hit-path hypotheses were widened and came back 0 of 20. The
safe-linking reading of the churn addresses (same day) said "a freed small
malloc block read as a pointer". The collector reads exactly one malloc'd
table unlocked across a stop — the chunk index; the finalizer tables and root
list are held locked across `stop_world` (`stop_world_quiescing_roots`). A
~20 k-pause spin between `realloc` and the publish raised the TLAB harness's
loss from ~1 in 900 to 1 in 20 with the same signature.

## The fix

Allocate, copy, publish with a release store, then free the old array. Every
state a suspended thread can leave names an intact array: the old one until
the store, the fully copied new one after it. Growth holds `@index_lock`, so
locked readers never see the switch.

## The gate

`make index-grow-race`: one `Isolated` thread grows the heap to 160 MiB (2 KiB
atomic objects, ~1300 chunks, the index doubling ~7 times), stamping each
object; main collects back to back; `GCRY_INDEX_GROW_TEST_STALL_MS=50` holds
every growth at the point that matters. At the end every object must be
allocated and carry its stamp.

| arm | result |
|---|---|
| shipped (allocate, copy, publish, free) | 3 of 3 clean, 1 400+ collections each |
| `GCRY_INDEX_GROW_FREE_FIRST=1` (free, then publish — `realloc` when it moves) | 6 of 8 faulted; required ≥ 1 of 5 |
| calling `realloc` itself, 20 ms | 1 of 3 (it grows in place when it can) — why the red arm frees directly |
