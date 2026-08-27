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


---

## The mostly-empty arm: two more refutations, and why the arm cannot be measured yet

Two candidate fixes were built and measured against `dormant_flush_race`'s
`GCRY_MOSTLY_EMPTY=1` arm, interleaved with v0.21.1 child by child:

**Build the mask under the class's freelist lock.** `alloc_old_small_locked`
pops a block and calls `set_used` on it under that lock, and between the two
the header still reads FREE — so an unlocked mask can call a page free while a
mutator is already writing an object into it. Locking the mask removes that
window provably.

    v0.21.1  10 of 40      locked mask  5 of 40

**Hold the lock across the mask, the re-read and the syscalls.** The locked
mask alone still leaves "lock released → mutator allocates and writes →
`madvise` fires", and `MADV_FREE` is not cancelled by a write that happened
*before* the call.

    v0.21.1   2 of 40      lock across syscall  5 of 40

The second is worse than its own control. And the two controls are the **same
binary**: v0.21.1 gave **10 of 40** in one batch and **2 of 40** in the next.

That is the finding worth keeping. At n=40 this arm's baseline swings by more
than any effect being looked for, so the "10 → 5" reading above is withdrawn
too — it is inside the noise of the control's own movement. Both changes were
reverted; neither is supported.

## What this arm needs before another fix is tried

A stable rate, or a bigger one. Measuring a 5–25% defect by 40-child batches
against a control that moves between 5% and 25% cannot resolve anything, and
three attempts have now been spent learning that rather than learning about the
defect. The next step is not another candidate fix — it is either far more
samples per arm, or a harness knob that widens the window deliberately so the
defect becomes frequent enough to measure cheaply (`GCRY_STW_TEST_*` exists for
exactly that shape of problem elsewhere in this tree).


---

## A fourth refutation, and it is the useful one

`GCRY_PAGE_RELEASE_TEST_STALL_MS` was added to widen the mask-to-syscall gap on
purpose, so that a defect living in that gap would become frequent enough to
measure a fix against. It does the opposite:

| stall | faults |
|------:|-------:|
| 0 ms | **2** of 12 |
| 2 ms | **0** of 12 |
| 10 ms | **0** of 12 |

If the mechanism were "a mutator allocates into a page the mask called free,
before the `madvise` lands", widening that gap would raise the rate. It does
not. So the `0x18` corruption on the mostly-empty walk is **not** coming from
that gap — which retires the model behind all three candidate fixes tried
above, and explains why none of them moved anything.

What is left standing is the other half of `MADV_FREE`'s semantics. A page is
reclaimed only if it has not been *written* since the call, and a **read** does
not cancel it. The freelist nodes in a released run are followed by reads.
So a chain walked through a reclaimed page reads zero, allocation returns a
bogus pointer, and the object built at it is the null-shaped thing that
`stop_world` later dereferences at +0x18.

That predicts a different fix — do not leave freelist nodes inside `MADV_FREE`d
pages — and a clean experiment that does not exist yet: **`MADV_FREE` plus the
unlink**, without switching to `MADV_DONTNEED`. The one mode that unlinks today
(`GCRY_MOSTLY_EMPTY_MODE=dontneed`) also switches the syscall, so its 7 of 30
cannot separate the two changes.

The knob stays. Its answer is negative and that is worth a minute of anyone's
time to re-check.


## And the fifth: the unlink arm does not hold up either

`GCRY_MOSTLY_EMPTY_UNLINK=1` was added to run the experiment the model above
predicted — `MADV_FREE` **plus** the unlink, without the syscall change that
`MOSTLY_EMPTY_MODE=dontneed` makes at the same time. Interleaved:

| batch | `MADV_FREE` | `MADV_FREE` + unlink |
|-------|------------:|---------------------:|
| 60 each | 11 | 5 |
| 25 each | 1 | 3 |
| **combined, 85 each** | **12** | **8** |

Fisher exact ≈ 0.48. The first batch looked like a halving and the second
reversed it; together they are nothing.

## Where this arm actually stands

Five candidate fixes, five nulls:

1. extend the unlink to this walk — the mode that already unlinks was worse
2. build the mask under the class freelist lock — inside the control's own swing
3. hold the lock across mask, re-read and syscall — worse than its control
4. widen the mask-to-syscall gap on purpose — the rate goes **down**, retiring
   the model behind 1–3
5. `MADV_FREE` + unlink, separated from the syscall change — p ≈ 0.48

The honest reading is that this arm cannot currently be measured: its baseline
moved between 2 and 11 per 40–60 children across batches of the same binary,
which is larger than any effect looked for. Continuing to propose fixes against
it produces readings, not knowledge — three of the five above were believed for
an hour each before the next batch withdrew them.

What it needs is a reproducer with a stable rate, or a diagnostic that catches
the corrupting write rather than the crash that follows it. Until then the knob
stays opt-in, off by default, documented unsound, and out of CI — which is
where 0.21.1 already leaves it.
