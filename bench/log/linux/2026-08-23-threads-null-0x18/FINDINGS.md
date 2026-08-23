# `0x18` is `Thread.@@threads` reading null

2026-08-23, Linux x86_64. **Open.** The address is identified; the cause is not.

Two harnesses now produce the same crash under a page-release walk —
`dormant_flush_race` (3 of 24 with `GCRY_MOSTLY_EMPTY=1`) and the new
`live_graph_audit` (2 of 12 with `GCRY_PAGE_DONTNEED=1`). Both land here:

    Invalid memory access at address 0x18
    pthread_mutex_lock
    Thread::Mutex#lock
    Thread::lock
    Gcry::Heap#stop_world
    Gcry::Heap#stop_world_quiescing_roots
    ... maybe_collect <- allocate <- GC.malloc_atomic

## What 0x18 is

From Crystal's `crystal/system/thread.cr`:

    @@threads = uninitialized Thread::LinkedList(Thread)
    def self.threads; @@threads; end
    def self.lock : Nil
      threads.@mutex.lock
    end

A fault at exactly `0x18` means the base was zero, so either `@@threads` reads
null or the `LinkedList`'s `@mutex` field does. The second is a field of a heap
object, and a heap object's field reading zero is what a released page leaves
behind. The first is a global in BSS, which gcry scans as a root and never
writes.

The crash happens at collection 8 to 22 with four threads already running, so
"not yet assigned" is not available as an explanation.

## Hypothesis tested and eliminated: a madvise outside its chunk

`release_free_pages_in_chunk` derives the page range from a chunk header and
then checks it against `data_start`/`data_end` **from that same header**. That
is a self-consistency check: it says the header agrees with itself, not that the
header belongs to a live chunk. A live-world walk that stepped onto a released
or foreign header would build a range out of whatever is at that address, and
`MADV_DONTNEED` on it would zero memory gcry does not own — BSS included.

`madvise_range_ok?` now checks the range against the chunk's own mapping and the
heap span, counts what it rejects, and skips the syscall.

    12 runs, GCRY_PAGE_DONTNEED=1:  range_rejects 0, every run

So the range never leaves its chunk, and this is not how BSS would be reached.
The check stays anyway: it costs two comparisons, it turns an unbounded hazard
into a counted one, and `GCRY_MADVISE_UNCHECKED=1` restores the old behaviour if
anyone needs the old shape back.

## What the graph audit says, and what it cannot

`bench/live_graph_audit.cr` shadows every node of a live object graph in
`LibC.malloc` memory the collector cannot see, then checks the graph against the
shadow and the shadow against raw memory each round. It separates a broken edge
from a zeroed node from a reused node, because those are three different
defects.

Across every run: **edges 0, zeroed 0, reused 0, payload 0.** Its own graph is
never damaged. The crash happens anyway.

That is consistent with the remaining candidate — the object being zeroed is one
the *runtime* allocated early and holds for the life of the process, not one
this harness owns. It is not evidence for it. The next instrument has to shadow
`Thread.threads` itself, so a null shows up as a report at the round it happens
in rather than as a fault in the next `stop_world`.

## Rates

    live_graph_audit, 12 attempts per arm
      no walk        0 of 12,   1.4 MB released
      HOLED          2 of 12,   107 MB released
      mostly-empty   0 of 12,   120 MB released

The mostly-empty arm released *more* and did not fault, which is worth keeping:
whatever this is, it is not simply a function of how many pages get released.
