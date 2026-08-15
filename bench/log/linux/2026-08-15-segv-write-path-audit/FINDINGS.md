# What could have written to that address — an audit, and three eliminations

**Date:** 2026-08-15 · analysis against the 2026-08-10 soak (`d36effe`), verified
on tip · host: WSL2 x86_64, Crystal 1.21.0

The board's next step for the unexplained soak SEGV reads: *"consider whether
anything else mutates scheduler state outside the collector's view."* This is
that audit. It does not find the bug. It removes three readings that were open,
and it says which instrument would settle what is left.

## Every place gcry writes to memory it did not allocate

There are two, and neither was active in the crashing run.

**1. The parked-fiber scrub.** `stack_scrub.cr` zeroes a parked fiber's stack
below its estimated SP — a write into memory Crystal owns, from another thread,
with a margin measured at **zero** (clean through 56 bytes of overshoot on
x86_64, corrupt at 60). If anything gcry does could corrupt a live frame, this is
it.

It was **off**. `93776f4` ("gcry: default the parked-fiber scrub off",
2026-08-09) is an ancestor of `d36effe`, the commit the 2026-08-10 soak ran:

```
$ git merge-base --is-ancestor 93776f4 d36effe && echo ancestor
ancestor
```

**2. Disappearing links.** `clear_and_remove_link_at` writes a null into a
caller-provided `Void**` when the referent dies, inside STW. That is a
write-anywhere primitive by contract: the slot must outlive the registration, and
gcry cannot check it. `bench/soak.cr` uses it at ~10 Hz — and correctly: the
registering fiber is a `loop do … end` that never returns, so the stack slot it
passes stays inside a live frame for the run's duration. Nothing here can write
outside that frame.

That is the whole list. Every other write gcry makes is to its own chunks: block
headers, freelist links, the mark bitmap, and the size-class carving.

## Three readings of `0x7f1700000149`, and what survives

The value has been read three ways across three sessions. Two can now be closed.

**"A valid pointer into a chunk that had been unmapped" — eliminated.** Under the
soak's configuration gcry released no empty chunks at all.
`release_empty_chunks_this_collect?` returns `@parallel_empty_chunk_dormant ||
@parallel_empty_chunk_munmap` whenever more than the main and monitor threads
exist, and both properties default **false**. The soak runs on the default
`Parallel` execution context with a worker per CPU, so that branch is the one it
takes. No `munmap`, no `MADV_DONTNEED`, no chunk left the address space — so no
address in the heap span was unmapped, and the fault cannot be a read of
returned memory.

**"An explicit free of a live block" — eliminated.** `bench/soak.cr` calls no
`GC.free`. Its only GC API calls are `GC.collect`. Every free in that run came
from the sweep, which means the block was judged unreachable, which means the
question is a missed root and not a bad free.

**"A block freed and reused while the scheduler still pointed at it" — survives**,
and is now the only reading with nothing against it. It requires the mark phase
to have missed a root.

## Which roots could have been missed, under *that* configuration

The crash was in `quick_dequeue?`, so the object in question is a `Fiber` in a run
queue. Its root chain in the soak's build:

- `Thread.@execution_context` → the `Parallel` context, pinned by name.
- → `@global_queue`, pinned; the `GlobalQueue` object is then scanned
  conservatively, which reaches `@list.@head`, which marks the head `Fiber`,
  which is itself scanned conservatively, which reaches `@list_next`, and so on
  down the chain.
- → each scheduler's `@runnables`, pinned; the ring is 2 KB of pointers inside
  one small block, scanned conservatively end to end (`clamped_scan_size` is the
  size class's payload, and the header's size equals it — no truncation).

Both structures were pinned *before* today's work, and neither depends on the
layout tables: the soak sets no `GCRY_AUTO_LAYOUTS`, so `Fiber`, `GlobalQueue`
and `Runnables` have no precise entry and are scanned word by word. **So the two
root defects fixed today cannot explain this crash either** — which was already
stated for the layout one and is now stated for the pin one.

What that leaves, honestly:

- a root path that is covered in the source but did not run — the shape of both
  v0.19.0 defects, and the reason `ec_root_pins` exists;
- a race between the collector and the scheduler that is not a root question at
  all;
- corruption from outside gcry.

## What each instrument would now say

Nothing here is a fix, and the point of the audit is to know what the next crash
proves rather than to argue about it again:

| the next crash | what it means now |
|---|---|
| `gcry: … freed-block poison … in the faulting context` | use-after-free, full stop — `GCRY_POISON_FREED` |
| `… in a FREE block, size N, first word 0x…` | the collector had given the memory back |
| `… in a USED block …` | reissued, or a bad offset into a live object |
| `… outside gcry's heap span` | never a gcry allocation; a swept object is not the explanation |
| `EC QUEUE SLOT CORRUPT … not a live Fiber` **before** the crash | the slot went bad at a known collection, hours of guessing removed |
| `EC STRUCTURE CORRUPT … @runnables …` | the container itself was reissued, which the slot walk could not have said |

A 90-minute local run with all of them on (`--fiber-churn=128`) is in progress as
this is written: 125 collections, 2 694 queue slots walked, 41 of them on
non-empty queues, **0 faults**, no crash. That is not evidence of absence — the
CI crash took 1h24m — it is the instruments running clean under load, which is
what they have to do before a red one means anything.
