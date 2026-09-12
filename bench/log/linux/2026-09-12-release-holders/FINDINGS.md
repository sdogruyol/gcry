# The released block was garbage: asking the holders question at the release

Date: 2026-09-12 · host: AMD Ryzen AI 9 465, Linux 7.2.4 · tree `3ddc8bc` +
this change · knob `GCRY_RELEASE_HOLDERS=1`

## Why the fault-time answer never settled anything

Every sighting of the open live-large-object release ends the same way:

> holders — none. Nothing in the root set, in a live block or on a fiber
> stack points into it, so the pointer is in a register, in thread-local
> storage, or in memory gcry never mapped

And that search runs **from the fault** — which on this defect arrives
**109 collections** after the release (`GCRY_TRACE_LARGE`: allocated at
collection 94, released at 96, written at 205). "Nothing points into it" is
unsurprising at that distance and says nothing about the moment that matters.
The question had never been asked at the **decision**.

`GCRY_RELEASE_HOLDERS=1` asks it there: every large release runs the holders
search, silently, and speaks only when something points into the block.

## What it found

The knob fires on roughly one run in five of `thread_churn_uaf --child`:

```
gcry: RELEASING A BLOCK SOMETHING POINTS AT — large chunk 0x7ffa50d4d000,
      user 0x7ffa50d4d030, 77776 bytes, at collection 182,
      0 of the stack words are above the collector's entry SP (live mutator frames)
gcry: holders — explicit roots: 0 of 4 point into it — gcry is not rooting it
gcry: holders — heap: block 0x7ffa50b7f420 size 32 type_id 0 flags 0x0 holds it at +8
gcry: holders — heap: 1 word(s) in 1 live block(s), from 42503 block(s) in 23 chunk(s)
gcry: holders — stacks: 11 word(s) across 4 stack(s)
        ... all 11: below the collector's entry SP, i.e. inside the collection's own frames
gcry: owner — and who points at that holder? [0x7ffa50b7f420, 0x7ffa50b7f440)
gcry: owner — explicit roots: 0 of 4 point into it
gcry: owner — heap: 0 word(s) in 0 live block(s)
gcry: owner — stacks: 11 word(s), all below the entry SP as well
```

So, at the instant of release:

| where | words pointing into the block |
|---|---|
| explicit roots | **0** |
| live blocks | 1, in a 32-byte `type_id 0` block that **nothing** points at |
| stacks, above the collector's entry SP | **0** |
| stacks, inside the collection's own frames | 11 |

**The block was garbage, and so was its only heap holder.** A 32-byte
`type_id 0` block holding a pointer at +8 is a raw `GC.malloc` buffer — the
shape of a discarded intermediate, which fits `GC.realloc` growth having
already moved on. The eleven stack words are the collector's own copies of the
pointer it is in the middle of releasing.

## The verdict line, and why it needed two tries

A holder on a *running* fiber's stack is unattributable on its own: below its
SP is dead space a few calls left behind, and `Fiber#@context.stack_top` is
stale for exactly the fiber that is running. Two floors were tried.

1. **`Platform.thread_sp`, the SP the stop recorded per thread.** Right idea,
   no data: the table is zeroed at resume, so the post-STW release path reads
   an empty one. `clear_thread_sps` now keeps a retained copy
   (`Platform.last_stop_sp`) for the post-STW section — cheap, ≤ 64 words per
   collection — and it still reported **0 threads**, correctly: in this
   workload nothing is suspended at the stop that later holds the pointer. The
   hits are all on the **collector's own** stack.
2. **`@collect_entry_sp`, which the collector already records.** That is the
   line between the mutator's frames and the collection's. Above it, a slot was
   a live mutator frame when the mark phase read it, and an unmarked block
   would be a missing root. Below it, the slot belongs to the collection.
   Measured: **0 above, 11 below**, every time.

## What this changes

The open item has said since 2026-08-23 that a *live* large object is released.
Measured at the release, it is not live: nothing in the root set, nothing in a
referenced live block, nothing in a mutator frame. The release is **correct**.

So the defect moves. The write that faults 109 collections later goes through
a pointer that no longer exists anywhere the collector can see — a register, a
dead stack slot, or memory gcry never mapped, which is the same three-way split
the holders sentence has always ended on, except now it is measured at the
decision instead of inferred at the fault. Two of those three are no longer
open questions on this heap: registers are spilled and scanned for every
suspended thread and for the Monitor (2026-09-12), and thread-local storage
became a root the same day. What is left is dead stack and non-gcry memory.

The next instrument is therefore not about the sweep at all. It is: at the
*fault*, which stack frame or register does the writing pointer come from —
i.e. a backtrace of the writer, not of the reader. `GCRY_SEGV_REPORT` prints
the faulting context already; what it does not do is name the frame that
produced the address.

## Cost

The search walks the root set, every live block and every stack per released
chunk, with the world up. On the reproducer that is ~100 releases per run over
a 42 500-block heap and it roughly doubles the run. Research only, silent
unless it finds something, and documented as such.
