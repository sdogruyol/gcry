# A zeroed object at `0x18`, and a walk that did not turn out to explain it

2026-08-23, Linux x86_64. **Open.** A crash with no established cause.

The title this file was first given — "the mostly-empty walk zeroes live
objects" — claimed a mechanism that a purpose-built harness then failed to
reproduce. What follows is what was actually seen, and what was mistakenly
inferred from it.

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

## The mechanism written here first was wrong

The original version of this file blamed `unlink_free_only_page_runs` and TLAB
blocks it cannot see. That function is called **only when
`@mostly_empty_dontneed` is set**, which needs `GCRY_MOSTLY_EMPTY_MODE=dontneed`.
The run that produced the crash set `GCRY_MOSTLY_EMPTY=1` and nothing else, so
the default mode was MADV_FREE and that function never ran. The mechanism was
written from reading the wrong branch.

What does run is `release_free_pages_in_chunk`: it builds a live-page mask by
reading every `BlockHeader.free?` in the chunk holding no lock, then madvises
the runs the mask calls free. The window between that read and the syscall is
real. Whether anything falls into it is a separate question, and the answer so
far is no.

## A harness built to catch it, that did not

`bench/page_release_corruption.cr` gives every live object a checksum derived
from its own bytes and re-verifies everything it holds each round, so a zeroed
page is caught whether or not it is ever dereferenced as a pointer. It counts
`dontneed_bytes` so that a clean result can be told apart from a run that never
reached the path — the first version of the harness spread its survivors one per
page, no chunk ever went HOLED, nothing was released, and it looked clean.

With survivors clustered so whole page runs go free:

    GCRY_MOSTLY_EMPTY=1     0 of 6 corrupt, 97 MB released
    GCRY_PAGE_DONTNEED=1    1 of 6 corrupt, 118 MB released
    default                 1 of 6 corrupt, 0 B released

Rebuilt with the control arm as the floor rather than zero — `dontneed_bytes` is
shared with `flush_pending_dormant_chunks`, which answers to the empty-chunk
machinery and not to `madvise_free_pages`, so the control releases a few MB no
matter what — and re-run:

    GCRY_PAGE_DONTNEED=1    0 of 6 corrupt, 132 MB released
    GCRY_MOSTLY_EMPTY=1     0 of 6 corrupt,  97 MB released
    GCRY_DISABLE_MADVISE=1  0 of 6 corrupt,   6 MB released

The verifier is not silently broken: zeroing a held object on purpose reports
40 corrupt, all forty entirely zero.

The default arm in the earlier table releases nothing and still showed a
failure, so that column was the harness's own noise — three arms back to back on a loaded machine, and the
child hit its timeout. Re-run quiet, the default arm is 0 of 10. The
`GCRY_PAGE_DONTNEED` failure is the same artefact.

So: **no measured corruption from either walk.** The HOLED path also has a
defence the alarm here did not account for — chunks marked HOLED go through a
freelist rebuild in STW (`rebuild_mask`), so blocks inside the free page runs
cannot be handed out between the mask and the syscall.

## What is actually still open

The crash is real and unexplained. `bench/dormant_flush_race.cr` on HEAD fails
**3 of 24** with `GCRY_MOSTLY_EMPTY=1`, and the frame is
`stop_world -> Thread.lock -> pthread_mutex_lock` faulting at `0x18` — a zeroed
object, not a chunk header and not a swept block. Turning the knob off gave 0 of
8, but eight samples do not separate 0 % from 12 %, so even that link is thin.

What is not established: that the mostly-empty walk causes it. A harness built
specifically to catch that walk zeroing an object found nothing in six runs
while releasing 97 MB.

`GCRY_UNMAP_GUARD=1` does not help here either way. The guard turns `munmap`
into `mprotect`, so a use-after-release faults instead of corrupting; `madvise`
is untouched. Clean runs under the guard say nothing about these paths.

## What this cost

Three conclusions were drawn today from runs too small to support them, and each
had to be withdrawn — see `../2026-08-23-heap-dump-walk/`. A fourth was drawn
from reading a branch that the tested configuration does not execute. The
`dontneed_bytes` counter in the new harness exists because of the fourth: it is
the difference between "nothing went wrong" and "nothing happened".
