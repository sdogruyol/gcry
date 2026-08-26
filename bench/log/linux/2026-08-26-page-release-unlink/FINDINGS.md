# Closing the page-release window: take the pages out of circulation

2026-08-26, Linux x86_64. **Closed** for the HOLED walk
(`GCRY_PAGE_DONTNEED=1`). Still open for the mostly-empty walk — see the end.

## The window

`release_free_pages_in_chunk` builds a mask of free pages by reading every
block header in the chunk, then `madvise`s the runs the mask calls free. It
runs after `start_world`, so a mutator can allocate into one of those pages
between the mask and the syscall, and `MADV_DONTNEED` then zeroes a live
object.

A re-read immediately before the syscall was already there and is not enough:
it closes the window from "mask built" to "about to release" and leaves the one
from "checked" to "syscall issued".

## What did not work, measured

Holding the **size-class freelist lock** across the re-read and the `madvise` —
serialising the release against the allocator. With the lock in place the gate
still crashed **5 of 40**. Serialisation is the wrong tool: the syscall is not
the thing that has to be atomic with the check.

That attempt is also what surfaced the stop-the-world hang fixed in 0.21.1, so
it was not wasted, and it is written down so nobody tries it twice.

## What worked

Take the pages **out of circulation** before the syscall: unlink the free-only
page runs from the class freelist, under the class's freelist lock, then
`madvise` outside it. A block that is not on the freelist cannot be handed to
anybody, which is a different guarantee from re-reading a mask and a stronger
one.

The machinery already existed — `unlink_free_only_page_runs` — and was wired
only to `@mostly_empty_dontneed`, a research mode. It was never applied to the
HOLED walk, which is the one `GCRY_PAGE_DONTNEED=1` turns on and the one that
uses `MADV_DONTNEED`.

## Measured

`page_release_corruption` children, `GCRY_PAGE_DONTNEED=1`, 120 s deadline,
arms interleaved child by child:

| Tree | faults | hangs | children |
|------|-------:|------:|---------:|
| v0.21.1 | **8** | 0 | 40 |
| with the unlink | **0** | 0 | 40 |

Fisher exact p ≈ 0.003, and it accumulated evenly — 2, 4, 6, 8 at each ten —
rather than arriving in one unlucky batch.

Engagement is printed rather than assumed: the arm reports `unlinked 9496`, so
a clean result cannot be the unlink never running.

## Still open: the mostly-empty walk

The `GCRY_MOSTLY_EMPTY=1` arm reports `unlinked 0`, correctly — the unlink is
gated on `preserve_content == false`, and that path uses `MADV_FREE`, which
preserves content.

Preserves it **until the kernel reclaims**. A reclaimed page reads zero, so a
freelist node followed by a read, or a live object's bytes, can still come back
zeroed — which is exactly the shape of the open `0x18` crash
(`bench/log/linux/2026-08-23-zeroed-object-0x18/FINDINGS.md`), where a live
`Thread` reads as null and `stop_world` faults at +0x18 dereferencing it.

That guess was measured and is **wrong**. `GCRY_MOSTLY_EMPTY_MODE=dontneed` is
the one mode that already unlinks before releasing, so if unlinking were the
fix it should be the clean arm. Interleaved, 30 children each:

| mostly-empty mode | faults |
|---|---:|
| `MADV_FREE` (no unlink, the default) | **2** of 30 |
| `dontneed` (unlinks, then `MADV_DONTNEED`) | **7** of 30 |

The arm that unlinks is the worse one. Not significant at n=30 (p ≈ 0.15), but
there is no support here for extending the unlink, and it matches what that
mode's own documentation says about churn.

In hindsight the mechanisms differ. Unlinking stops a **free** block from being
handed out between the mask and the syscall. The `0x18` crash is a **live**
object — a `Thread` — reading back as zero, which means the mask called a page
free while a live object sat in it. Taking free blocks off the freelist does
nothing about that.

So the open question for the mostly-empty walk is narrower than it looked: not
"can an allocation slip in", but **why does the mask call a page free when it
holds a live object**. The candidate worth instrumenting is the in-flight
window inside allocation itself — a block is popped from the freelist and its
header still reads FREE until `set_used` runs, so a mask taken in between calls
its page free while the mutator is already writing an object into it. That is a
measurement to take, not another guess to ship.
