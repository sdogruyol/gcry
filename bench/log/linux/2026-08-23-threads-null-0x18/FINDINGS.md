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

## Three more probes, none of which fired

Added to `live_graph_audit`, in order, each because the previous crash landed
somewhere the harness could not describe:

1. **The runtime thread list.** `stop_world` crashes on `Thread.@@threads`
   reading null, and by then the round it happened in is gone.
   `Thread.unsafe_each` goes through `@@threads.try`, so it reports the same
   emptiness without faulting. Never fired.
2. **Liveness before dereference.** `Heap#address_in_live_chunk?` (new, public)
   asks the heap whether an address is still mapped, so an audit can find a
   released chunk instead of faulting on it. Applied first to the revive pass,
   then to a sweep over every shadowed node and payload at the top of each
   round. Never fired.
3. **The runtime's `Thread` objects, shadowed.** Recorded on the first round and
   checked before each `unsafe_each` walk. Never fired.

The crash continued through all three, in the worker proc, always
`inside the heap span but in no live chunk`.

## Why "check first, then read" does not close it

The sweep asks the heap at the top of the round. It cannot keep the answer true:
the verification pass allocates nothing, but the *other three workers* do, and a
collection they trigger can release the chunk mid-walk. So a probe that does not
fire is not evidence of a live object — only that the window moved.

This is the same shape as everything else here: an instrument that cannot see
what it is aimed at goes quiet rather than saying so. The `dontneed_bytes`
counter exists for that reason, and so does the engagement floor, and so does
`BoundedChild` reporting a timeout apart from a fault.

## Two results from this file were invalid, and why

Adding a diagnostic line broke the harness silently. `STDERR.puts` from a thread
started with `Thread.new` raises `Thread#execution_context cannot be nil` —
Crystal's IO reaches for the current execution context and a bare thread has
none. Every child died in its first round from then on.

The hunts run in that window are withdrawn:

- **0 of 46** was not a clean result. The children were dying before they
  verified anything, and the hunt was grepping for `Invalid memory access`,
  which this exception is not.
- **20 of 20 in both arms** was not "the defect is in both arms". It was the
  same bug seen from the other side, every child failing for a reason that had
  nothing to do with gcry.

The second one is the more instructive: a result that symmetric and that clean
is far more likely to be a broken harness than a finding, and it was only caught
by looking at what a child actually printed. Diagnostics now go through
`write(2)`, which needs none of the runtime's machinery.

## The instrument does not suppress what it measures

Worth checking, because the liveness sweep asks the heap 3000 times a round per
worker and each ask takes `@index_lock` — enough mutator-side synchronisation to
plausibly change the timing of the race. It does not:

    sweep on    dontneed 10.4 MB, 14.2 MB
    sweep off   dontneed 13.2 MB, 10.0 MB

`LIVE_GRAPH_SWEEP=0` turns it off so this stays checkable.

## After the repair

The defect still fires — 2 of 6 in the first runs after the fix, which is in
line with the pre-repair rate and unlike the invalid 0 of 46. The fault address
is not inside any large payload (the harness prints their ranges and matches
arithmetically), and the round-start sweep does not flag it, which is expected:
the sweep asks once and the other workers keep allocating, so the window moves.

What is still unknown is which object the address belongs to.

## Rates

    live_graph_audit, 12 attempts per arm
      no walk        0 of 12,   1.4 MB released
      HOLED          2 of 12,   107 MB released
      mostly-empty   0 of 12,   120 MB released

The mostly-empty arm released *more* and did not fault, which is worth keeping:
whatever this is, it is not simply a function of how many pages get released.
