# Chunk-list walks that run with the world running

2026-08-23, Linux x86_64. Found by continuing the lock-discipline sweep, not by
a crash report.

## The shape

Three `flush_pending_*` passes run after `start_world`, deliberately: the
`madvise` calls they issue are slow and the design keeps them out of the pause.
They walk `@chunks` holding nothing. The call site says they are "still under
post-STW mutex" — true, and irrelevant: `@post_stw_mutex` serialises collectors
against each other, and no mutator ever takes it.

A mutator does reach the chunk list from outside. `GC.free` of a large object
lands in `trim_large_cache`, which unlinks chunks and unmaps them. Crystal's own
GMP binding installs `GC.free` as libgmp's free hook, so a program that touches
`BigInt` gets there without ever writing `GC.free`.

The segfault is the mild outcome. The walks compute a page range from a chunk
header and hand it to `madvise(MADV_DONTNEED)`; issued after the kernel has
reissued that range to somebody else's `mmap`, it zeroes live memory and leaves
nothing to find.

## The gate

`bench/dormant_flush_race.cr` (`make dormant-flush-race`): four workers
allocating, writing, verifying and `GC.free`ing a 40 KiB block; one thread in
`GC.collect`; 40 000 small objects of ballast so the walk is long. Two arms —
default, and `GCRY_TRIM_IMMEDIATE=1` restoring the mutator's own unmap.

Under `GCRY_UNMAP_GUARD=1` the release is `mprotect(PROT_NONE)`, so the fault
lands on the spot and names the chunk instead of surfacing later somewhere else.

    default (before the fix)   6 of 6
      SIGSEGV ... in a chunk gcry RELEASED — 45056 bytes, large-object
      release, at collection 1; the write is 28 bytes into it

28 bytes into the header is `ChunkHeader.set_sparse`, the third line of
`flush_pending_mostly_empty_chunks`. Reading the header is the unsafe act, not
the `madvise`: all three passes dereference every chunk before they test the
flag that would make them skip it.

## What it took, and what each attempt got wrong

**Queue unconditionally.** Mutators stop unmapping; the collector drains. Wrong:
the queue then drains once per collection, and a `GC.free` loop parks gigabytes
of detached-but-mapped chunks in between. Measured as a null `mmap` and a fault
at `0x18` — a different crash, 5 of 6, wearing the fix as a disguise.

**Queue only while a walk is live.** `@live_chunk_walk`, set and cleared under
`@alloc_lock`. A mutator holding the lock and seeing it false knows no walk can
start before it lets go, so it unmaps on the spot; seeing it true, it queues.
The walk still takes no lock, so allocation is not stalled across its syscalls.
Still 6 of 6 — with the *original* signature.

The counters said why the guessing had to stop. The next sighting named the
frame: `Gcry::Heap#sweep`. The lazy sweep (`after_world: true`) is a fourth
walker over the same list, with the same exposure, and was not covered.

Covered it. Fifth sighting: `release_large_freelist_pages`. That one is a
different problem wearing the same clothes — it walks a structure mutators
*edit*, not just memory they can unmap. `take_large_free` hands an entry to user
code, which writes over the `next_free` the walk is following. The flag cannot
help; that walk needs `@alloc_lock` and has to keep it across its `madvise`
calls, because an entry taken between a snapshot and the syscall is live memory
by the time the syscall lands.

    default (after)            0 of 6
    GCRY_TRIM_IMMEDIATE=1      6 of 6

## How wide the window is

From the instruments in one child run: 846 walks, 33 519 mutator trims diverted
into the queue, 3 676 released directly. The window is not a sliver — in this
workload a walk is in flight for most of the trims. That is why it was 6 of 6
rather than something that needed hunting.

## Not claimed

Nothing here is attributed to the acikturkiye crash. That one stopped
reproducing before it could be tested against any of today's fixes, and it stays
open (`bench/log/linux/2026-08-23-acik-crash/FINDINGS.md`).

No `madvise`-onto-reissued-memory event was observed. It is what the code
permits, not something caught happening; every sighting recorded above is a
header access, not a syscall.
