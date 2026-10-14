# Freeing one large chunk walked the chunk list (2026-10-14)

## What was left open

`bench/log/linux/2026-10-01-large-free-quadratic/` batched the trims: the
collector's trim and an explicit `GC.free` past `LARGE_FREE_TRIM_SLACK`
(2 MiB) remove their chunks in one pass over the list and one over the index
(`Heap#unlink_detached_large`). A trim of a single chunk kept
`Heap#unlink_chunk`, and so does a free of a block bigger than the slack when
nothing else is cached: the chunk list is singly linked, and the unlink
walked it from the head to the chunk in front of the target. As many steps as
the target sat deep, every free.

## The measurement

`unlink_scale.cr` (beside this file) keeps n 64 KiB objects alive with 200
4 MiB objects spread evenly among them, so each 4 MiB object sits about n/2
deep whichever way the last sweep's rebuild turned the list. It times the 200
frees; each puts the cache past the slack and trims its chunk alone.
Release build, Linux, this host (QEMU virtual CPU, 12 vCPUs), per free,
median of three runs (the three in brackets):

| live large chunks (indexed) | before (6dc6e7d) | after |
|---:|---:|---:|
| 2 500 (2 720) | 9.64 µs (9.59, 9.64, 9.68) | 4.08 µs (3.52, 4.08, 4.30) |
| 10 000 (10 220) | 35.38 µs (30.93, 35.38, 35.49) | 4.82 µs (4.66, 4.82, 4.92) |
| 40 000 (40 220) | 186.11 µs (170.62, 186.11, 197.28) | 7.70 µs (7.51, 7.70, 8.25) |

The 2026-10-01 harness, `largefree_scale.cr` (n 64 KiB objects, all freed
oldest first), gains as much, one run each:

| live large chunks | before (6dc6e7d) | after |
|---:|---:|---:|
| 2 500 | 2.93 µs | 1.63 µs |
| 10 000 | 7.91 µs | 1.33 µs |
| 40 000 | 41.71 µs | 1.48 µs |

Those frees are under the slack, and the batched trim measured there
(10.9 µs at 40 000) was without large-object recycling, the Linux default
since 2026-10-06. Under recycling a `GC.free` trims the cache to the
recycling budget instead, at least the retain plus the slack, and once the
cache is that full each free past it trims one chunk: of 2 500 frees, 2 470
went through `unlink_chunk` (`Heap#chunk_unlinks`, counted on the fixed
tree, where they walked 0 steps), with 2 MiB left cached.

## Where the rest goes

A copy of the tree with timers around the unlink's index section (not
committed) ran the same harness:

| indexed | per free | `index_remove` | back-link check |
|---:|---:|---:|---:|
| 2 720 | 4.13 µs | 0.31 µs | 0.061 µs |
| 10 220 | 4.90 µs | 1.08 µs | 0.068 µs |
| 40 220 | 7.74 µs | 3.82 µs | 0.091 µs |

`index_remove` is the lock, the radix removal, a binary search and the shift
of every entry above the target down by one. The shift is what grows: about
0.09 ns per indexed chunk. At 40 000 it is half the cost of a free; the other
~4 µs is about the same at every size ([INFERENCE] the `munmap` of the 4 MiB
mapping and the trim's bookkeeping). It does not dominate at these sizes, and
removing it needs an index that is not a sorted array, which is what every
`chunk_containing` binary-searches. Left as is.

## Where the back-link lives

`ChunkHeader` is 32 bytes and full, and growing it to 40 puts every small
chunk's first block off its 16-byte alignment. The other places looked at:

- A large chunk's `data_offset` and `bitmap_words` are constants, but
  `data_start` reads `data_offset` for every chunk on the allocation and
  mark paths; giving them a second meaning on large chunks means a branch
  there.
- The large block header's `next_free` is free while the block is
  allocated, but the trims unlink exactly the cached chunks, whose
  `next_free` chains the cache bucket.
- A side table keyed by chunk would need its own protocol against the
  in-STW sweep, which rewrites the list without a lock.

So large chunks carry 16 more bytes of metadata, between the chunk header and
the block header (`ChunkHeader::LARGE_LINK_BYTES`):

    [ChunkHeader 32][back-link 8, unused 8][block header 16][object …]
     0               32                     48               64

The object starts at 64 instead of 48, still 16-aligned. A mapping is
`align_up(64 + payload, page)`, so it grows by a page only for a payload in
the 16 bytes below a page multiple minus 48: 36 801–36 816 bytes is a
40 960-byte mapping now and was 36 864. Small chunks are unchanged. Every
site that recovered a large chunk as `header - ChunkHeader::SIZE` (17 in
`src/`) goes through `ChunkHeader.from_large_header`.

## Keeping it

The link names the chunk whose `next` is this one, or null at the head. It is
written wherever a `next` or the head is set to a large chunk, under the same
exclusion as that store: `map_chunk` (the new head and the old one),
`unlink_chunk`, `unlink_detached_large`'s list pass, the sweep's rebuild (each
`kept` gets the chunk linked to it), `publish_relinked_chunks` and the
pending-empty flush's relink.

One store pair races. The after-world rebuild writes the links of the chunks
it walked without the list lock, and a `map_chunk` landing during the walk
writes the link of whatever heads the list under the lock — until the first
prepend, the chunk the walk started from. The rebuild has meanwhile put that
chunk behind another, so `publish_relinked_chunks` rewrites its link under the
lock. `make chunk-list-drift`'s window arm maps a large chunk in exactly that
window every collection; its children now audit the links after each
collection (`Heap#chunk_back_link_faults`). Without the rewrite the audits
found a wrong link in 293 of 300 collections; with it, none.

## Trusting it

`unlink_chunk` follows the link only after checking it, in the same
`@index_lock` section as its index removal: the chunk the link names must be
in the index (nothing unmaps an indexed chunk without taking it out under that
lock, so its `next` can be read) and its `next` must be the target. Otherwise
it walks, as before, and counts the steps (`Heap#unlink_walk_steps`). The
link is wrong only where the list's own `next`s already are — a writer frozen
inside its locked section while an in-STW sweep relinks, or the
`GCRY_TRIM_UNLOCKED` control — and there a wrong link costs a walk rather
than a fault.

## Tests

- `process_spec/regression/71_large_unlink_walks_nothing_spec.cr`: a 4 MiB
  block between two runs of 256 large blocks, a collection, then `GC.free`.
  On 6dc6e7d with the two counters added it fails: the free walked 283 steps
  (bound 16). After: 0, and no wrong link before or after.
- `spec/heap_spec.cr`, "unlinks a large chunk by its back-link wherever it
  sits in the list": single unlinks from every depth of a library heap's
  list, before and after a collection that rebuilt it in reverse; no walk
  step, no wrong link, list and index the same length. On 6dc6e7d with the
  counters it fails: its first 16 unlinks walked 376 steps.
- `make chunk-list-drift`: the window arm's audits, above; it passes, with
  `back-links wrong 0` over 300 prepends in the window.

Also passed on the fixed tree: `crystal spec -Dgc_none spec/all_specs.cr`
(281 examples) and with `-Dgcry_block_headers` (303), `crystal spec
-Dgc_none process_spec` (198) and `GCRY_BITMAP_ALLOC=0` with
`-Dgcry_block_headers` (199), `make large-cache-race`, `make
realloc-move-stress` (its in-place arm included), `make windows-typecheck`,
and the aarch64-darwin cross type check of `samples/hello.cr`, the specs
and 71.
