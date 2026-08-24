# `MADV_DONTNEED` on pages that still hold live objects

2026-08-24, Linux x86_64. Measured. Narrowed, not closed.

`release_free_pages_in_chunk` builds a live-page mask by reading every block
header in the chunk **holding no lock**, then `madvise`s the page runs the mask
calls free. Mutators keep allocating in between.

Counted at the syscall, past every bounds and range check, so it only counts a
run actually about to be dropped:

    GCRY_PAGE_DONTNEED=1   30, 31, 5, 41 live blocks in released runs
    GCRY_DISABLE_MADVISE=1  0

A live block inside a run getting `MADV_DONTNEED` is that object zeroed. This
is a correctness defect on its own terms, whatever else it does or does not
cause.

## The fix, and its limit

Re-read the run's headers immediately before the syscall — the last moment the
answer is current — and skip the run if anything in it is live. About **6 runs
per child** of `live_graph_audit` are skipped that would otherwise have been
released with an object in them. `GCRY_PAGE_RELEASE_UNCHECKED=1` restores the
old behaviour and the skip count drops to 0, which is how the arm is known to
be doing something.

It narrows the window from "the whole mask computation" to "a few
instructions"; it does not close it. A TLAB hand-out between the re-read and
the syscall still lands in a run about to be dropped. Closing it properly means
stopping allocation into the chunk for the duration — the class freelist lock
plus parking TLABs — which is a heavier change and is not made on an argument.

## It does not explain the crash it was found chasing

Against `bench/live_graph_audit.cr`'s use-after-free:

    re-read on    3 of 24
    re-read off   5 of 24

p ≈ 0.70. So the hazard is real and the fix demonstrably skips live runs, but
neither the hazard nor the fix moves that crash. Two possibilities, untested:
the residual window is enough on its own, or the crash has a different cause
and this is a second defect found on the way.

Recorded this way round on purpose. The earlier version of this alarm — raised
on 2026-08-23 and withdrawn when `page_release_corruption` found no corruption —
was withdrawn for the wrong reason: that harness checksums leaf objects, and
what gets lost here is a *holder*. The retraction was correct about the evidence
and wrong about the hazard.
