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
