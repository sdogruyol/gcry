# A chunk-index rebuild that could not run

2026-08-23, Linux x86_64. Closed.

`Heap#ensure_chunk_index` rebuilt the sorted `@chunk_index` from the `@chunks`
list, guarded by `@chunk_index_dirty`, and was called from
`each_static_range_excluding_heap` during mark. It never ran once.

`@chunk_index_dirty` appeared in exactly two places in the whole tree: read in
that guard, and written `false` at the end of the rebuild. Nothing ever wrote it
`true`, and nothing declared it, so Crystal inferred `Bool?` and started it at
`nil` — `return unless nil` returns every time.

Counted rather than argued: **0 rebuilds** across runs of 18 collections.

## Why removing it is safe

The index is maintained incrementally and the paths are complete:

- `map_chunk` -> `index_insert`
- `unlink_chunk` -> `index_remove` (heap.cr)
- the sweep's drop path -> `index_remove` before the chunk goes on
  `@pending_empty_chunks` (collect_sweep.cr)

So the rebuild had nothing to repair. Removing it changes measured behaviour by
nothing: specs 169/0, `stw-index-race` still two-directional (0 unlocked
mutator reads against 10 166 in the late-clear arm), `find-block-race` still
green with its control arm still crashing.

## Why it was worth removing rather than leaving

It reads as a safety net. While chasing the page-release use-after-free, this
file's author treated it as a live rebuild that might explain a stale index, and
spent time there before checking whether it runs.

That is the third structure found today whose comment had outlived its
condition: the STW watchdog reporting a cleared breadcrumb as "waiting for
thread 0x0", `Heap#realloc` justifying a pin with a type_id gate that
`GC.init` turns off for stacks, and this. All three read as live and all three
were only caught by counting.
