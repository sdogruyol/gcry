# A chunk released with a live block in it, read for the first time

Date: 2026-09-14 · CI run `34787711949` (x86_64, 2 vCPU) · local host: AMD Ryzen
AI 9 465, 8 cores · tree: `96832b8`

## The sighting

One of the 18 overnight CI runs failed `make thread-churn-uaf` on its guarded
arm, and the report said something no sighting of this defect has said before:

```
gcry: SIGSEGV at 0x7f6e5cea0014 — in a chunk gcry RELEASED — base
0x7f6e5cea0000, 131072 bytes, empty size-class chunk release, at collection 206;
the write is 20 bytes into it. Collections since: 0.
Blocks still allocated at release: 1
```

It could say it because of the fix landed hours earlier: the release ledger used
to be consulted only for addresses *inside* the heap span, and releasing a chunk
is what moves an address out of the span, so exactly these faults used to print
"never a gcry allocation, so a swept object is not the explanation".

**"Blocks still allocated at release: 1"** is a popcount of the chunk's
occupancy bitmap taken at the moment of release. So this is not a stale mutator
pointer into memory that was legitimately freed: it is a live block inside
memory the collector gave back, and "Collections since: 0" says the write
happened in the same collection as the release.

## The window, from the code

1. The sweep decides a chunk is empty, unlinks it from `@chunks` **inside the
   stop**, and queues it on `@pending_empty_chunks`.
2. Its `@chunk_index` entry survives — `index_remove` runs in the post-STW
   flush, deliberately (`collect_sweep.cr`: "the entry leaves the index here,
   immediately before its memory goes").
3. The allocator resolves a pooled chunk address through **that index**
   (`bitmap_indexed_chunk`) and accepts the chunk if `bitmap_pool_candidate?`
   likes it — and that predicate accepts a chunk whose blocks are all free,
   which a chunk queued as empty is by construction.
4. Under multi-mutator STW the flush runs after `start_world`. So between the
   stop ending and the flush running, a mutator can legally take a block out of
   a chunk that is already queued for unmapping.

## The fix

Refuse. `flush_pending_empty_chunks_locked` now re-reads each queued chunk's
occupancy immediately before releasing it, and a chunk with any allocated block
is kept mapped and **put back on the live list** so the next sweep sees it
normally. Refusing cannot lose: a chunk kept costs RSS, a chunk unmapped under a
live block costs the object.

`refuse_live_release` did not cover this — it asks whether another *indexed
chunk* lives inside the range, not whether this chunk still holds blocks — and
under `GCRY_UNMAP_GUARD=1` it is not even reached, because `guard_release`
short-circuits the `unless A || B || C`.

Two counters make the state legible: `release_flush_chunks` (chunks the flush
considered) and `release_refused_occupied` (chunks it refused).

## What could not be reproduced locally, and why that is informative

The window was never reached on this host — 0 refusals in 24 churn children with
the flush held 20 ms, on 8 cores and pinned to 2, and 0 in a purpose-built
harness. The counters say why:

| workload | chunks the flush considered |
|---|---|
| churn, several mutators alive, 120 collections | **0** |
| single-threaded allocate/drop, 30 collections | **37** |

With mutators alive the sweep does not queue empties at all — they go dormant
and stay linked — so there is nothing to release and no window. Single-threaded,
the queue fills, but then there is no second mutator to take a block. Reaching
the window needs **both**: the sweep on its single-mutator path *and* a mutator
running when the flush walks the queue, which is the thread-birth window the
churn reproducer hits about once in twenty-four children on a 2-vCPU runner and
did not hit here in 48 attempts.

`GCRY_EMPTY_FLUSH_DELAY_MS` widens the second half and `GCRY_RELEASE_OCCUPIED=1`
restores the pre-fix behaviour for a control; `bench/occupied_release.cr` runs
both and refuses to pass when it reaches nothing, which is what it currently
does here. It is research, not a gate: a gate that cannot reach its own window
on the host it runs on proves nothing.

The test is the next CI sighting. Where the guarded arm printed a fault, it
should now print `refusing to release chunk 0x… — the sweep queued it empty and
N block(s) are allocated in it now`.
