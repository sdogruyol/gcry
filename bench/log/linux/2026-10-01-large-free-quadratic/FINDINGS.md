# Freeing a large object costs O(live large chunks) (2026-10-01)

## Symptom

`pattern_fuzz` timed out at 900 s in the Stride phase (array growth up to
128 KiB) once in about 300–1 200 runs, single-threaded, always with the same
stack: `GC.free` → `free_owned?` → `trim_large_cache` → `unlink_chunk`. There
were four sightings: campaign-036 seed 20102, campaign-044 seed 20149,
campaign-045 seed 20109, and the stride-only reproducer (`stride_repro.cr` in
campaign-046) seed 20012. All of them were in the `+diag` lanes. The first two
were read as a chunk-list cycle, and the walk was bounded and given a report.
The report never fired.

## What the captures say

The last two were captured with gdb against a `--debug` build, with
`info locals`:

| sighting | `unlink_chunk` limit (2 × index + 64) | steps at the snapshot | detach loop step |
|---|---:|---:|---:|
| campaign-045 seed 20109 | 58 262 | 13 981 | 1 |
| campaign-046 seed 20012 | 100 932 | 45 768 | 1 |

There is no cycle. The index held 29 000–50 000 chunks, against about 2 500
in a normal Stride run. Every large `GC.free` on Linux trims immediately
(large-cache retain 0). Each trim unlinks the chunk, and `unlink_chunk` walks
the singly linked chunk list from the head to find the predecessor.
`index_remove` also shifts the sorted index. Both are O(n) per free.

## The cost, measured

`largefree_scale.cr` (beside this file) allocates n 64 KiB objects, keeps
them all, then frees them one by one. Release build, this host:

| live large chunks | free all | per free |
|---:|---:|---:|
| 2 500 | 11 ms | 4.5 µs |
| 5 000 | 51 ms | 10.3 µs |
| 10 000 | 192 ms | 19.2 µs |
| 20 000 | 746 ms | 37.3 µs |
| 40 000 | 3 536 ms | 88.4 µs |

Quadratic. A program that holds tens of thousands of large buffers and
releases them pays seconds. `pattern_fuzz` gets there when conservative
retention keeps several phases' worth of the Stride phase's large blocks
alive at once. After a phase's `GC.collect`, about 2 500 of them are still
`USED` (the census in `stride_repro.cr`), held through a stale word to the old
`live` array's buffer.

## Why the index grew: dangling pointers into recycled address ranges

`stride_census.cr` (beside this file) is the Stride phase alone. When the
index passes 8 000 chunks it stops, counts what is in the index, and runs the
holders search on every retained `live` buffer. A buffer is recognised by its
first word pointing into the heap; the stride blocks themselves are zero.
It tripped in the plain lane at phase 4 (campaign-046, seed 20088):

    CENSUS phase=4 index=10061 small=44 large_free_on_list=0 large_free_off_list=0
           large_used=10017 ... counter=0MiB twice=0 taken_used=0

So nothing was stuck on a freelist. Ten thousand large blocks were alive.
The holders of the retained buffers:

- one buffer was held by its 32-byte `Array` object, which a stack word held
  (the usual one-phase retention after `live = [] of Pointer(Void)`);
- the others were held by **other buffers**. One buffer had 5 holders, each
  pointing *into* it at `block+4096` or `block+36864`.

[INFERENCE] The harness frees every even entry with `GC.free` and keeps the
pointer in its `live` array. Linux trims a freed large chunk at once
(retain 0) and unmaps it, and the next large `mmap` reuses that range. The
dangling entry now points into whatever was mapped there, often a later
phase's `live` buffer. The offsets fit: a freed chunk whose base sat 4096
bytes above a new buffer's base reads as `buffer+4096`. One buffer held by a
stale stack word then holds, through dangling entries, buffers from later
phases and every block they point at. The chain grows phase by phase, and
the quadratic free does the rest.

This is conservative scanning meeting a program that keeps dangling pointers,
with address reuse quick enough to land them on live objects.

Nulling the freed entries was not enough. A run with it still tripped, and
there the holders were the `live` array's **growth buffers**: 3 072-,
6 144-, 10 240-, 16 384- and 24 576-byte blocks, each left behind when the
array doubled, each with a copy of the pointers taken before the nulling.
Campaign-047 ran the census harness three ways (stride phases only, 200 per
run, index over 8 000 counted):

| harness | runs | tripped |
|---|---:|---:|
| as before: freed entries kept | 251 | 5 (2.0%) |
| freed entries nulled | 181 | 2 (1.1%) |
| `live` preallocated, freed entries nulled | 321 | 0 |

At 2%, 0 in 321 has a probability of about 0.15%. `pattern_fuzz` now
preallocates `live` to the phase's size and nulls what it frees.
`GCRY_RELEASE_QUARANTINE=N` holds released ranges `PROT_NONE` for N
collections, and it would also break the chain; it was not measured here.

## The collector's trim: batched (2026-10-03)

The same cost hit the collector harder. A sweep that finds k large objects
dead caches them all, and the trim after it (Linux retain 0) removed them
one `unlink_chunk` at a time, holding `@alloc_lock`, so every allocating
mutator waited. `large_trim.cr` (beside this file) keeps n 64 KiB objects
live and lets k die per collection. It reports the median `GC.collect` time
of 8 rounds, release build:

| live n | dying k | before | after |
|---:|---:|---:|---:|
| 2 000 | 2 000 | 39.2 ms | 18.4 ms |
| 10 000 | 2 000 | 93.0 ms | 14.5 ms |
| 20 000 | 5 000 | 909.4 ms | 76.4 ms |
| 40 000 | 5 000 | 2 286.5 ms | 111.9 ms |

`unlink_detached_large` flags the k chunks (`ChunkHeader::Flags::UNLINKING`),
compacts the index in one pass and the list in one pass: O(n + k) instead of
O(k·n). A trim of one chunk keeps `unlink_chunk`, whose walk stops at the
predecessor. `spec/heap_spec.cr` ("trims several interleaved large chunks")
pins it. It went red both ways it was broken: with the list pass skipped
(`each_chunk` then walked into an unmapped chunk) and with the index
compaction skipped.

The explicit `GC.free` path trimmed one chunk per call, so batching alone
left `largefree_scale.cr` unchanged: 13.6 µs per free at 10 000 and 81.6 µs at
40 000. `free` now trims only once the cache holds
`LARGE_FREE_TRIM_SLACK` (2 MiB) past the retain, and then trims all of it:

| live large chunks | per free, trim each | per free, 2 MiB slack |
|---:|---:|---:|
| 2 500 | 4.5 µs | 2.4 µs |
| 10 000 | 13.6 µs | 3.1 µs |
| 40 000 | 81.6 µs | 10.9 µs |

The collector still trims to the retain after every collection, so the
post-collection footprint is the same; between collections at most 2 MiB
more stays mapped. `make idle-rss-after-burst`, `rss-leak`, `oom-no-hang`
and `parallel-dormant` pass. `dormant_flush_race`'s scheduled control had a
peer's `free` trim the chunk it holds. That peer now calls the trim itself,
which is the mutator path the arm is about.

## Not fixed here

O(1) removal needs a doubly linked chunk list, and `ChunkHeader` is 32 bytes
with no room. A `prev` field breaks the 16-byte alignment of a large chunk's
payload, and the "by construction" offsets that rely on `data_offset == SIZE`.
The sorted index's removal also shifts. Cheaper options that keep the
structures:

- Batch the unlink. Have `trim_large_cache` detach a set of chunks and remove
  them in one pass over `@chunks` (O(n + k) instead of O(k·n)). That only helps
  when a trim removes many chunks.
- Hysteresis on Linux's large-cache retain of 0: trim only past a small slack,
  then trim to the floor, so trims come in batches. This is an RSS policy
  change.

Both are open in ROADMAP.

The `+diag` lanes (`GCRY_POISON_FREED=1`) are where all four sightings were.
Poisoning a 64–128 KiB payload makes each free slower, which brings the
timeout closer. Whether poisoning also changes how much is retained was not
measured.
