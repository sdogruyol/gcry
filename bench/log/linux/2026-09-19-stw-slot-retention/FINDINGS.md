# What Linux's fixed 64-slot capture table cost

2026-09-19, this host (20 cores, Linux 7.2.4, Crystal 1.21.0), `-Dgc_none`,
headerless default.

`ROADMAP.md` said in three places that Linux keeps its STW capture table at a
fixed `MAX_STW_SP_SLOTS = 64` deliberately, because a thread with no slot loses
**precision and not roots**: its registers arrive in a signal `ucontext` that
sits on its own stack, and the scan of that stack runs unclamped, so it still
walks them. That is true, and it is now checked (`held` arm below). What nobody
had measured was what the unclamped scan *costs*.

## Retraction first

The first version of this note claimed the cost was **retention**: 98 threads
and 96 unreachable blocks left 34 still allocated after one, two and three
collections, 62 threads left zero, and the survivors were the blocks the threads
past the 64th had allocated. The numbers were real; the attribution was wrong.

    GCRY_DISABLE_LAZY_SWEEP=1, 98 threads, 96 unreachable blocks   → 0 still allocated
    default (lazy sweep),      98 threads, 96 unreachable blocks   → 34 still allocated
    default (lazy sweep),      62 threads, 60 unreachable blocks   → 0 still allocated

It is **lazy sweep**: one collection's eager pass had not reached those chunks
yet, and `34 = 98 - 64` was a coincidence — which the follow-up made obvious,
because after the capture table grew the count stayed 34 while the *identity* of
the survivors moved (`first_still_allocated` 62 → 57, and 62..95 → a scattered
set under `GCRY_ALLOC_BATCH=1`). A number that matches a hypothesis and an
identity that does not is not a measurement of that hypothesis.

Commit `9d1b051` carried the wrong reading, and `make stw-slot-precision` was
built around it. Both are corrected here rather than deleted: the harness
measures the mechanism below, and the roadmap entry is rewritten in place.

## The cost, measured

The mechanism is real and it is the scan window. With no capture slot there is
no recorded SP, so `fiber_stack_sp_scan_low` finds none for that thread's own
stack — a Crystal thread's main fiber's stack **is** its OS stack — and
`fiber_stack_scan_top` falls back to `guard`: the whole 8 MiB mapping, instead
of the live frames above the SP.

98 threads parked, 8 collections, same binary, the table pinned by
`GCRY_STW_FIXED_SLOTS=1` in the second row:

| table | capacity | claims refused | stacks scanned from an SP | from the guard page | per collection |
|---|---|---|---|---|---|
| growing | 128 | 0 | 768 | 8 | **23–29 ms** |
| pinned at 64 | 64 | 493–672 | 512 | 264 | **506–672 ms** |

Read off the counters: 8 guard-page fallbacks across 8 collections is one per
collection — the collector's own running fiber — against 33 per collection when
34 threads have no slot. The pause goes up about **twentyfold**, and it is the
same work every collection for the life of the process.

Repeatability: the two counter pairs are identical across runs (768/8 and
512/264 at 8 collections); only the millisecond figures move.

The half that was already argued does hold, and the `held` arm checks it: with
the table pinned, 96 blocks whose only pointer sits in the allocating thread's
own stack all survive. An uncovered thread does not lose roots. It pays for them
with the whole mapping.

## The fix

Linux now uses the same growable table as Darwin and Windows
(`Gcry::StwSlots`), sized from the thread count at collection entry —
`reserve_stw_slots(listed + 8)` from `stop_world`, under `Thread.lock`, before
the first suspend signal, so `malloc` never happens in a handler or inside the
stopped world, and the table never frees its predecessor.

Three copies of the same quartet are now one. Linux needed three things the
shared table did not have, and they are in it rather than beside it:

* a **CAS claim**, because this platform's suspend handler keeps a fallback
  claim for a thread that appeared after the reservation loop, and those run on
  every thread at once. A plain store gave two threads one slot: latent while a
  slot held only an SP and a register row, a hang once the stop epoch stamped a
  served epoch under the loser's index.
* a per-slot **served epoch** and **acknowledgement byte**, which is where they
  already lived on Linux — the handler must not touch Crystal at all, because a
  thread signalled between `Thread.threads.push(self)` and
  `Thread.current = self` has no TLS and Crystal's accessor *creates* one,
  allocating and taking the list mutex the collector holds.
* a **register count** per slot rather than a flag, because
  `with_thread_gregs` hands the raw row and its length to `StackMaps`, which
  resolves DWARF register locations by index.

`GCRY_STW_FIXED_SLOTS=1` works here now too, which is what gives both gates on
this platform a red direction: `make stw-capture-coverage` (80 threads, 0
refused claims against 62 pinned) and `make stw-slot-precision` (the table above).

## Method notes

Two mistakes worth keeping.

**The first version of the harness was written over `bench/stack_bounds_growth.cr`**
— a tracked file, a different gate for a different table, built three days
earlier — because the name matched what I was measuring. Restored from `HEAD`
with no loss. `git log --oneline -1 -- <path>` before writing a bench file.

**And the retention story survived three measurements before it died**: the
count, the index range, and the knob A/Bs that ruled out the pthread-mapping
path and the register scan all agreed with it. What killed it was the one arm I
had not run — the collector's own sweep knob. A hypothesis that explains the
number it was built from is not yet a measurement; the arm that can refute it is.
