# The after-world sweep's occupancy publish is not losing blocks

Date: 2026-09-12 · host: AMD Ryzen AI 9 465, Linux 7.2.4 · tree `c84b438` +
this change · harness `bench/sweep_occ_race.cr`

## The hypothesis, and why it was worth an afternoon

`../2026-09-12-thread-churn-large-uaf/` localised the open live-large-object
release to the post-STW sweep on the bitmap allocator:
`GCRY_DISABLE_LAZY_SWEEP=1` **0/36** and `GCRY_BITMAP_ALLOC=0` **0/36**
against a baseline of 25/36, with no coverage knob moving it. What that leaves
is the sweep losing a live block's occupancy, and there is an obvious
candidate — the publish itself:

```crystal
o = occ[i]
m = mark[i]
dead = o & ~m
occ[i] = m        # whole-word store
mark[i] = 0_u64
```

A read-modify-write of a word the allocator writes with an **atomic OR**, from
a mutator holding **no lock** (`heap.cr`'s unlocked hit path and
`bitmap_alloc.cr`'s locked one). Between reading `mark[i]` and storing it, a
mutator could publish a block in that word and the store would erase it: one
live block per race, and a chunk that then reads empty enough to release.
Which is the shape of the defect, exactly.

The comment at the store did not help. It said:

> The whole-word store is kept, and it is not incidental: a per-bit clear
> would race a mutator setting a different bit in the same word.

True, and about a different question. It says why a per-bit clear is wrong, not
why the store is right — and read alone it invites the conclusion that the
store is the bug. It has been corrected.

## The instrument

`in_flight` is a cursor slot's own answer to *"which block am I handing out
right now"*: set before the occupancy store, cleared once the block is built,
on both allocation paths. `GCRY_SWEEP_OCC_AUDIT=1` asks, per dead word,
whether any slot points into a block this pass just called dead. Such a block
is occupied, live, unmarked and about to be returned to a caller — the state
allocate-black exists to prevent, and the one the publish would lose.

The audited pass is `Kernels.sweep_words` written out word at a time with that
one question added: the arithmetic and the store are the kernel's, so the knob
changes what is observed and not what is done. The poisoning arm already had
that shape and answers through the same counters.

## Measured

| run | words published with mutators live | `sweep_occ_in_flight` |
|---|---|---|
| `sweep_occ_race`, 120 rounds × 12 threads born per round | **283 259** | **0** |
| `thread_churn_uaf --child`, poisoned arm, 6 runs | **183 360** each | **0** each |

482 380 kept blocks were checked across the first run — held through each
collection by a class-variable slot, payload verified byte by byte — and none
was lost or overwritten. The second row is the harness whose use-after-free
still fires at 15 of 18; the audit is silent on the very runs that fault.

## So the publish is sound, and here is why

None of the argument is local to the loop, which is why reading the loop
suggested otherwise:

* **Cursor sets are settled inside the stop** (`bitmap_settle_cursor_sets`).
  One frozen mid-allocation keeps its chunks `PINNED` and the after-world walk
  skips them (`sweep_cursor_pinned` 240 per reproducer run, 306 per probe run
  — the mechanism is load-bearing, not theoretical). An idle one is retired,
  and its owner has to come back through `bitmap_alloc_locked`, which takes the
  class lock the walk also takes.
* **Allocate-black.** A block handed out while `@collecting` carries `mark=1`,
  so it is not in `occ & ~mark`. `@collecting` stays true through the whole
  post-STW section, sweep included, and deliberately so.
* **A bit in `mark` but not in `occ` cannot exist**, because marking follows
  occupancy on both allocation paths.

## Attempted and reverted

An atomic publish — `occ &= ~dead` with the dead bits cleared by an
`atomicrmw And`, an `Acquire` load to pair with a `Release` on the allocator's
`occ` OR, and the allocate-black mark moved *above* the occupancy store on
both paths. It is sound and it is cheap. It is also a fix for nothing
measurable: a counter of bits that appeared between the load and the clear
read **0** over 71 325 words, including with a research knob that held each
dead word open for 200 µs. Reverted rather than shipped — the window it closes
is one the three arguments above already close, and the after-world sweep
would have lost the vectorised kernel to a scalar loop for it.

The ordering move was reverted for a second reason worth recording: the hit
path's mark is *deliberately* placed after the occupancy store, so that a
cycle beginning inside that window is caught by the re-read
(`heap.cr`'s note). Moving it without evidence trades a measured property for
an unmeasured one.

## What this leaves

The open item keeps its localisation — post-STW sweep, bitmap allocator — and
loses its most obvious mechanism. The remaining candidates are the parts of
that section that are *not* the small-block publish: the empty-chunk release
decision reading `counts.any_live`, and the large-object release path, which
shares the section but none of this bitmap machinery. `sweep_cursor_pinned`
being 240 per run says a great deal of that section's work is being skipped
rather than done, and what a skipped chunk's `live_objects` accounting does is
the next thing to read.
