# The mostly-empty walk zeroes live objects

2026-08-23, Linux x86_64. **Open.** Observed, not fixed.

This is the first defect in today's live-world-walk family caught actually
corrupting memory rather than faulting on a chunk header.

## The frame

`bench/dormant_flush_race.cr` on HEAD, `GCRY_MOSTLY_EMPTY=1`, fails **3 of 24**:

    gcry: SIGSEGV at 0x18 — outside gcry's heap span — never a gcry allocation
    ...
    pthread_mutex_lock
    Thread::Mutex#lock
    Thread::lock
    Gcry::Heap#stop_world
    Gcry::Heap#stop_world_quiescing_roots

`stop_world` locking Crystal's thread mutex, faulting at offset 0x18 of a null
base. Nothing here is a chunk header or a swept object: a live object's bytes
read back as zero. That is what `MADV_DONTNEED` leaves behind.

With `GCRY_MOSTLY_EMPTY=0` the same binary is 0 of 8. The walk is the cause.

## The window

`flush_pending_mostly_empty_chunks` runs after `start_world`. For each SPARSE
chunk it calls `unlink_free_only_page_runs`, which builds a live-page mask by
walking every block header, then unlinks freelist nodes inside the free runs —
and then `release_free_pages_in_chunk` **rebuilds the same mask, unlocked**, and
`madvise(MADV_DONTNEED)`s the pages the mask calls free.

Unlinking from the global freelist keeps *that* path from handing the pages out.
It does not cover **TLABs**: blocks already carved into a thread's local buffer
are not on the global freelist and are invisible to `unlink_freelist_range`. A
mutator can take one, write its object, and have the page zeroed underneath it —
the write landed after the mask read that block's header as free and before the
`madvise` reached the page.

`GCRY_UNMAP_GUARD=1` does not protect against this. The guard turns `munmap`
into `mprotect`, so a use-after-release faults instead of corrupting; `madvise`
is untouched and still zeroes. Every clean run under the guard says nothing
about this path.

## Not yet decided

The fix is a trade-off the repo has already made once in the other direction:
this work was deliberately moved out of STW because the `madvise` calls are slow
and the pause mattered. Putting the mask and the syscall back under one lock
undoes that; freezing TLABs for the class across the window is the alternative
and is more machinery. Neither has been tried.

## What this cost

Two conclusions were drawn from six-attempt runs of these harnesses and both
were wrong — see `../2026-08-23-heap-dump-walk/`. Six attempts cannot separate
0 % from 12 %.
