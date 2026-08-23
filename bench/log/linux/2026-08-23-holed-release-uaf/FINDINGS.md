# The HOLED page-release path frees a chunk that still holds a live object

2026-08-23, Linux x86_64. **Open.** Confirmed, not fixed.

`GCRY_PAGE_DONTNEED=1` — the Linux opt-in for the HOLED free-page release, and
the default on Darwin — makes `bench/page_release_corruption.cr` fault about one
run in six. With the same binary and the walk turned off, it does not fault at
all.

    GCRY_PAGE_DONTNEED=1     7 of 40
    GCRY_DISABLE_MADVISE=1   0 of 40

Both arms back to back on an otherwise idle machine. Fisher exact p ≈ 0.012.

## What faults

    gcry: SIGSEGV at 0x7f4a2043d028 — inside the heap span but in no live chunk
          — the chunk was unmapped, or the address is in a hole between chunks
    ...
    *Pointer(Slice(UInt8)) +9
    *Array(Slice(UInt8))  +31
    ~procProc(Thread, Nil)

The worker's own `kept` array, reading one of its elements. The array is live —
it is on the thread's stack and the worker is mid-loop — and its backing buffer
sits in memory gcry no longer counts as a live chunk.

So this is not the `madvise` hazard the harness was built to look for. Nothing
was zeroed. A chunk holding a reachable object was **released**, which is a
false free.

## What this overturns

Commit `66e248b` is titled "no live object is corrupted by the page-release
walks" and its record says the walks were cleared. The narrow claim survives —
no checksum ever failed, so no page was zeroed under a live object — but the
title is wrong about the path being safe, and the investigation was closed on
17 runs of an arm that fails at 17 %. The chance of missing it in 17 runs is
about 6 %, which is what happened.

## Where to look

The HOLED flag is set in STW (`collect_sweep.cr`, `set_holed(chunk, true)`) and
the chunk's size class is queued for a freelist rebuild in the same pass. The
release itself runs after `start_world`. Between the two the mutators are live
and allocating, and the rebuild decides which blocks are free. A chunk whose
live count is wrong after that rebuild is a chunk the sweep can decide is empty
and hand to `flush_pending_empty_chunks` to unmap.

That is a hypothesis about the mechanism; it has not been tested. What is
established is the arm, the rate, and the frame.

## The harness

`bench/page_release_corruption.cr` verifies a checksum on every live object each
round and reports `dontneed_bytes` per arm, so a run that never marks a chunk
HOLED cannot pass for a clean one. Its engagement floor is `max(4 × control,
8 MiB)` — a purely relative floor went vacuous when the control released 0 B in
one run, because that counter is shared with the dormant flush.

Not wired into CI: it is red.
