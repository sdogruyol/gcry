# The HOLED page-release path frees a chunk that still holds a live object

2026-08-23, Linux x86_64. **Open.** Confirmed, not fixed.

`GCRY_PAGE_DONTNEED=1` — the Linux opt-in for the HOLED free-page release, and
the default on Darwin — makes `bench/page_release_corruption.cr` fault about one
run in six. With the same binary and the walk turned off, it does not fault at
all.

    GCRY_PAGE_DONTNEED=1                      7 of 40   (HOLED walk, MADV_DONTNEED)
    GCRY_MOSTLY_EMPTY=1 GCRY_DISABLE_PAGE_RELEASE=1
                                              2 of 40   (mostly-empty walk, MADV_FREE)
    GCRY_DISABLE_MADVISE=1                    0 of 40   (neither walk)

All arms back to back on an otherwise idle machine.

The contrast that holds is **a page-release walk against none**: 9 of 80 with
one of the two running, 0 of 40 with both off, Fisher p ≈ 0.028. The two walks
are not distinguishable from each other — 7 of 40 against 2 of 40 is p ≈ 0.15,
and reading a mechanism into that gap is the mistake this file was rewritten
once already to avoid.

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

## A candidate, tested and eliminated

`rebuild_size_class_freelist` looked like the answer. It is the one thing the
HOLED path adds, it runs in the `after_world` branch with mutators live, it
walks `@chunks` — a sixth live-world chunk-list walker that the earlier sweep of
those walkers missed — and it is the only one that *writes*, overwriting the
header of every block it calls free. A live block wrongly on that freelist is
both relinked and overwritten, and free blocks are not traced during marking, so
whatever it points at is collected. That is exactly the shape seen here.

It is not the cause. The mostly-empty walk is HOLED-less by design and rebuilds
no freelist, and it fails too.

## What the two arms share

`release_free_pages_in_chunk`: build a live-page mask by reading every
`BlockHeader.free?` in the chunk holding no lock, then madvise the runs the mask
calls free. HOLED passes `preserve_content: false` (MADV_DONTNEED, zeroes now),
mostly-empty passes true (MADV_FREE, content survives until the kernel
reclaims). That ordering is consistent with 7 against 2, but the sample does not
carry the claim.

Note what the harness's own checksums say: **not one ever failed.** The
112-byte objects it verifies were never zeroed. What was lost is the *path* to a
2 MB buffer — the object holding the reference, not the leaf. A harness that
checksums only leaves cannot see that, which is why this took a crash to find
rather than a verification failure.

## The ledger names the victim

`GCRY_UNMAP_GUARD=1` could not be used here: it hides this fault (14 clean runs
against roughly 2 in 12 unguarded), which fits a fault that needs the range
reused — the guard prevents reuse by never returning the mapping.
`GCRY_RELEASE_LEDGER=1` keeps the guard's record and unmaps anyway:

    gcry: SIGSEGV at 0x7fef2eb2d050 — in a range gcry RELEASED and unmapped —
    base 0x7fef2eb2d000, 77824 bytes, large-object release, at collection 6;
    the write is 80 bytes into it. Collections since: 0

A 76 KiB **large** chunk, released through `cache_large_chunk` ->
`trim_large_cache`, and **Collections since: 0** — the release and the write are
in the same collection window. Not a stale pointer carried for a while: a race
inside the release itself.

Both victims seen so far are *growing* buffers — this one and the
1 970 176-byte Array buffer in `page_release_corruption`. That pointed at
`Heap#realloc`.

## The realloc window: a real hole that this workload never opens

`realloc` roots the old `pointer` across the copy because the type_id gate
rejects a raw buffer pointer as an ambient stack root. `fresh` is the same kind
of pointer and is **not** rooted; `@suppress_collect` covers the `allocate` and
is dropped before `copy_from`. On paper a peer thread's collection during the
copy is free to reclaim the block being copied into.

Rooting it was tried — and had been tried once before today and reverted as
"indistinguishable on 2 of 24", which was underpowered. With 40 per arm:

    fresh rooted     3 of 40
    fresh unrooted   1 of 40

Still nothing, and this time the reason is measurable rather than statistical.
`realloc_collect_overlaps` counts collections that begin while a thread is
inside the copy: **0**, across runs with 18 collections each. The window exists
in the code and is never entered here, so there is nothing to close, and the
rooting was reverted rather than shipped on an argument.

The counter stays. It answers the question directly in any workload — a
crash-rate A/B cannot separate a 5 % defect from a 2 % one without hundreds of
runs, but a collection starting mid-copy either happens or it does not. A
workload that reallocs hard (Kemal, acikturkiye) is where to ask it again.

## What is established

The arm, the rate, the frame, and that the freed object was live and reachable
from the mutator's own stack. Not the mechanism.

## The harness

`bench/page_release_corruption.cr` verifies a checksum on every live object each
round and reports `dontneed_bytes` per arm, so a run that never marks a chunk
HOLED cannot pass for a clean one. Its engagement floor is `max(4 × control,
8 MiB)` — a purely relative floor went vacuous when the control released 0 B in
one run, because that counter is shared with the dormant flush.

Not wired into CI: it is red.
