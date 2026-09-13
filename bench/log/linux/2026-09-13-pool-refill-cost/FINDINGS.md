# The refill walk is per capacity version, not per refill

Date: 2026-09-13/14 (overnight) · host: AMD Ryzen AI 9 465, Linux 7.2.4 ·
tree: `1aca3ed` · harness `bench/pool_refill_cost.cr`

`tasks/todo.md` has carried this since the bitmap allocator landed:

> `bitmap_take_pool_chunk` walks every chunk of the class per refill: O(chunks)

The code has changed under the note: the walk now builds a sorted index of
candidate addresses once per **capacity version**, and refills after that are
served from the index. So the question is whether the note is stale, or whether
versions change often enough that the walk is per-refill in all but name. That
is a counting question, not a timing one — which makes it answerable on a host
busy with an 8 h soak.

## The scaling

Four phases, each 40 collections and 163 840 allocations of 256 B, with a live
set that grows between phases so the class holds more chunks:

| live rounds | chunks | rebuilds | per 1 000 allocs | chunk visits / alloc |
|---|---|---|---|---|
| 1 | 29 | 80 | 0.49 | 0.0142 |
| 4 | 57 | 80 | 0.49 | 0.0278 |
| 16 | 165 | 80 | 0.49 | 0.0806 |
| 64 | 598 | 80 | 0.49 | 0.292 |

The rebuild count is **identical in every phase** — 80, i.e. 2.0 per collection
— while the chunk count grows 20.6x. So the cost per allocation grows 20.6x
too, exactly linearly, and extrapolating a 10 000-chunk class gives ~5 chunk
visits per allocation.

## What that means, and what it does not

It is not per refill: 163 840 allocations produce 80 rebuilds, one per active
class slot per collection — the size class and its atomic variant are two slots,
and each sweep bumps the version the index is keyed on. One rebuild per version
is the floor any per-version index pays.

The per-allocation growth is the arithmetic of a constant rebuild rate, not a
regression, and the number worth comparing it against is the sweep's own walk in
the same collection: the sweep visits every *block* of every chunk, 512 of them
per chunk at this size, so one visit per chunk per slot is **0.391% of a sweep
pass**. The churn arm, where the live set is dropped every round, comes out the
same: 2.0 rebuilds per collection.

So the note is retired as written. What survives is a documented cost rather
than a defect: *refill indexing costs one chunk-list walk per active class slot
per collection.* The shape of a fix, if a workload ever makes that 0.391% matter
— a heap with many chunks per class and very few blocks per chunk — is for the
sweep to hand the allocator the chunks with room instead of having the allocator
look for them; caching the walk harder cannot help, because the version it is
keyed on is invalidated by the sweep itself.

`make pool-refill-cost` keeps the measurement: it passes while rebuilds stay at
one per active slot per collection and fails if the index starts being
invalidated *inside* a collection, which is the only way this becomes the
per-refill walk the note described.
