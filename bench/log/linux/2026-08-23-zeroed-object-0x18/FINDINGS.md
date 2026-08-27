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

> **2026-08-26: that last sentence is withdrawn.** Eight samples against a
> defect this rare say nothing, and run interleaved at 80 per arm the knob goes
> the other way — see the section at the end of this file.

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

**That "0 of 6" for `GCRY_PAGE_DONTNEED` did not hold.** Run 40 times instead of
six, that arm faults 7 times — not on a checksum, on a released chunk still
holding a live object. It is a different defect from the one this file is about
and it is recorded in `../2026-08-23-holed-release-uaf/`. The narrow claim here
survives: no page was ever zeroed under a live object. The claim that the walk
was cleared did not.

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


---

## 2026-08-26: it took the v0.21.0 tag run red

`make dormant-flush-race` was wired into CI as a required step on 2026-08-25.
It passed on the `master` run of the release commit and then failed six minutes
later on the **tag** run of the same commit — the **default** arm, 1 of 3:

    queued (default):    1 of 3 failed
       gcry: SIGSEGV at 0x18 — outside gcry's heap span [0x7f1013d71000, 0x7f103f981000)
       — never a gcry allocation, so a swept object is not the explanation
    immediate (old):     3 of 3 failed

Same signature as this file's, and the gate's base env is what reaches it:
`GCRY_MOSTLY_EMPTY=1`. So this gate has always been running an open defect, and
wiring it in as required only moved that fact into the release's CI.

Rate remains machine-dependent and nobody's estimate is worth much at these
sample sizes: **3 of 24** when this file was written, **0 of 15** on the
workstation the day it was removed from CI, **1 of 3** on the runner.

The gate is out of CI again. It is still the right harness for this defect and
`make dormant-flush-race` runs it by hand; what it is not is a step that can
gate a release while the defect it exercises is open.


---

## 2026-08-26: the walk is not the cause

Every arm below is interleaved child-by-child on one machine, so the two arms
share the load rather than following each other through it.

    GCRY_MOSTLY_EMPTY=1     0 non-clean of 80,  0x18 in 0
    GCRY_MOSTLY_EMPTY=0     3 non-clean of 80,  0x18 in 1

The knob this file is named after is off in the arm that crashed. So the walk is
not what zeroes the object, and the file's original title claimed a mechanism in
the right family for the wrong reason.

Two further arms, same protocol, 80 children each:

    GCRY_DISABLE_MADVISE=1  1 non-clean of 80,  0x18 in 0
    default                 0 non-clean of 80,  0x18 in 0

Neither reaches the defect. The honest reading of all four is that the rate on
this workstation is around 1–3 %, which 80 children cannot resolve into a
difference between arms — an earlier batch the same afternoon gave 2 of 80 and
5 of 80 on the *same* two binaries. What the first table does support is the
narrow negative, because the crash appeared in the arm with the walk switched
off; what none of them support is any positive claim about which path is
responsible.

### What the frame does say

`Thread::Mutex#lock` is a real frame above `Thread::lock`, so the receiver was
fetched and `pointerof(@mutex)` then came out at `0x18`. That makes the null the
`@mutex` field of `Thread::LinkedList` — a field of a live heap object — and not
`@@threads` in BSS, which would have faulted one frame earlier.

Under `GCRY_UNMAP_GUARD=1` the same crash still appears (2 of 80 on v0.21.0's
binary). The guard turns `munmap` into `mprotect`, so no released range is ever
handed back by the kernel and no remap can write over that field. Whatever
produces the null is therefore not address reuse.

### The dying-type audit, aimed at the right types

`GCRY_THREAD_BLOCK_AUDIT=1` has only ever watched `Thread`. Aimed by type id at
`Thread::Mutex` and `Thread::LinkedList` as well, 8 children each:

    Thread::Mutex       dying_walked 2.1M,  dying_live 364,  dying_deaths 0
    Thread::LinkedList  dying_walked 2.0M,  dying_live  49,  dying_deaths 0
    Thread              dying_walked 2.4M,  dying_live 420,  dying_deaths 0

No block of any of the three is ever swept unmarked. (`dying_live` is far above
the number of real objects of each type, so the arm is also matching raw buffers
whose first word happens to equal the id — that inflates false positives and
leaves the zero above unaffected.) So the object is not being collected as
garbage. Whatever writes the zero writes it under a live, marked object.

### The double-release tripwire said nothing, twice

`note_release_base` fired in 21 of 24 children and none of those readings were
real: `guard_release` records under `@release_ledger || @unmap_guard`, but the
cancel side, `note_map_base`, was gated on `@release_ledger` alone. Run with the
guard and no ledger — which is how the crash arm runs — every legal reuse of a
base went unrecorded, so the next ordinary release of that base looked like a
double release.

With the cancel side armed to match, and its engagement counter reading ~30,000
remaps per child: `rel_double 0` across 77 children. There is no chunk-level
double release, and the reading that suggested one was the instrument's own
gating.


---

## 2026-08-27: the victim watched directly — confirmed, with a second presentation

The tripwire this file's title asked for exists
(`GCRY_THREAD_LIST_TRIPWIRE=1`) and was run 160/160 interleaved: every `0x18`
on the instrumented arm was preceded by "held 7 threads, reads empty", and 26
more crashes moved from `0x18` to faults *inside the walk*, at `+0x50` from the
base of a large-object chunk released one collection earlier — the list slot
held a payload-block pointer, not noise. The full batch, its numbers and what
they retire: `../2026-08-27-thread-list-tripwire/FINDINGS.md`.