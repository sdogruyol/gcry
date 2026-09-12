# The live large object, reproduced in a second without an application

Date: 2026-09-12 · host: AMD Ryzen AI 9 465, Linux 7.2.4 · tree `fedb7b4`
`make thread-churn-uaf`. Reached by following the thread-death reproducer
(`../2026-09-12-thread-life-root/`) past two wrong attributions.

## What this closes

`ROADMAP.md` has carried a defect since 2026-08-23 — *"A live large object is
released under load on the fat app"* — with this note:

> The rate fell from 7 of 60 to nothing for a reason that is not the knob, so
> **step one next time is re-establishing the baseline on the current tree**;
> until the crash reproduces at a resolvable rate, no arm here means
> anything.

That baseline now exists, and it needs neither `wrk` nor acikturkiye: eight
short-lived threads per round, one collection per round, 240 rounds. About a
second per attempt.

## Rates

| arm | headerless (default layout) | block headers |
|---|---:|---:|
| no knobs, no diagnostics | 14 of 942 (1.5%) | 16 of 924 (1.7%) |
| `GCRY_POISON_HOLDERS=1` | 4 of 24 | 2 of 12 |
| + `GCRY_THREAD_UNSTAGE_ON_DEATH=1` | 20 of 24 | 15 of 18 |

Two things to read off that table.

**It fires on the shipped default with nothing set.** Both layouts, ~1.5%
per 240-collection run. An earlier reading of "0 of 40" on this same
workload was simply underpowered — 40 runs at 1.5% expects 0.6 failures —
and was wrongly recorded as clean. Sample sizes here have to be in the
hundreds or they say nothing.

**Poison raises the rate by an order of magnitude** because it turns a stale
*read* into a fault instead of quietly returning recycled memory, and
`GCRY_THREAD_UNSTAGE_ON_DEATH=1` raises it again by removing the pre-stop
staged wait's spin — the accidental delay documented in the sibling log.

## The sighting

`GCRY_UNMAP_GUARD=1` releases a chunk with `mprotect(PROT_NONE)` rather than
`munmap` and keeps its identity, which is the difference between a named
chunk and "an address in no live chunk":

```
gcry: SIGSEGV at 0x7fc7c68d6030 — in a chunk gcry RELEASED — base
0x7fc7c68d6000, 212992 bytes, large-object release, at collection 62; the
write is 48 bytes into it. Collections since: 177.
gcry: holders — heap: 0 word(s) in 0 live block(s), from 10968 block(s)
gcry: holders — stack: fiber 0x… (running) slot 0x… holds block+0
gcry: holders — stack: fiber 0x… (running) slot 0x… holds block+48
gcry: holders — stacks: 17 word(s) across 5 stack(s)
```

`GCRY_TRACE_LARGE=1` ties the base to its allocation:

```
gcry: large map base=0x7fabd94e7000 mapped=57344 payload=56568 coll=94
gcry: SIGSEGV … base 0x7fabd94e7000, 57344 bytes, large-object release, at
collection 96; the write is 48 bytes into it. Collections since: 109.
```

Allocated at collection 94, **released two collections later**, written 109
collections after that. Sizes across sightings: 45 056, 57 344, 212 992
mapped — varying, so a growing buffer rather than one fixed structure. The
write offset is **+48 every time**. The first user word at release is a
pointer into the binary's own mapping, so the block is a buffer holding
pointers to static data, not a `Reference` (the report's `type_id` reading of
that word is nonsense and should be ignored).

This is the 2026-08-23 shape at a different size: a large-object chunk, the
large-object release path, no heap holder, and the range present on a
*running* fiber's stack.

## The ambiguity is resolved: this is primary

The first version of this file could not say whether the released chunk was
the *cause* or the backtrace printer's buffer, since a failing run usually
raises first. Settled by reading the whole of a failing child's stderr
rather than grepping it: on the `guarded` arm the SIGSEGV report is the
**first line**. Nothing precedes it. The released-chunk write is the first
event in the run.

That sighting also named a second release path:

```
SIGSEGV — in a chunk gcry RELEASED — base 0x…, 131072 bytes, **empty
size-class chunk release**, at collection 18; the write is 65632 bytes into
it. Collections since: 114.
```

So both paths do it: the large-object release *and* the empty size-class
chunk release.

## The bisect

With a reproducer this fast the knob matrix is a bisect. 36 attempts per
configuration on the header layout, amplified arm, baseline 25 of 36.

| configuration | failures |
|---|---:|
| baseline | 25/36 |
| `GCRY_SOUND=1` (maximal conservatism) | 25/36 |
| `GCRY_STACK_LOW_WATER=0` | 18/24 |
| `GCRY_FULL_SUSPENDED_STACK=1` | 20/24 |
| `GCRY_STW_STACK_LAG=0` | 21/24 |
| `GCRY_KEEP_CHUNKS=1` | 17/24 |
| `GCRY_CHUNK_RADIX=0` | 16/24 |
| `GCRY_TLAB=0` | 14/24 |
| `GCRY_PARALLEL_MARK=0` | 20/24 |
| `GCRY_BITMAP_ALLOC=0` | **0/36** |
| `GCRY_DISABLE_LAZY_SWEEP=1` | **0/36** |

Two readings, and the first one **retires this item's standing hypothesis**.

**It is not a missed stack or register root.** `GCRY_SOUND=1` turns on every
conservatism gcry has and changes nothing. Neither does removing the
pagemap low-water skip, the SP clamp, or the parked-fiber lag. The 2026-08-23
note reasoned from `GCRY_MARK_AUDIT=1` reporting 0 edges that *"the only
holder is a stack slot or a register, and the root scan is not seeing it"* —
but 0 edges is exactly what a stack-rooted buffer looks like, so that
inference never followed. Maximal coverage not helping is what settles it.

**It is the post-STW sweep, in the bitmap allocator.** Both zeros point at
the same path: `sweep_after_world?` restarts the world and *then* rebuilds
`@chunks` and unmaps empty chunks, on the stated assumption that it is the
sole mutator, with other threads held off by `@block_other_heap` when they
touch the heap. `GCRY_DISABLE_LAZY_SWEEP=1` removes that section and the
defect with it, deterministically. Anyone hitting this in production has a
one-variable mitigation.

## Three fixes attempted and withdrawn, with their numbers

Recorded so the next attempt does not re-spend them.

1. **Hold the large in-flight root past the handover.** `alloc_large_counted`
   clears `@large_alloc_in_flight` before returning, on the comment's
   reasoning that *"from here `u` is in the caller's registers or frame,
   which the scan accepts"* — which is false for a thread gcry does not
   scan. Keeping the root until the next large allocation: **29/48**, no
   change. The reasoning is still wrong; it is not *this* defect.
2. **Refuse the sole-mutator sweep when gcry knows of unlisted live
   threads.** The birth root can name threads Crystal's list lacks, so
   `sweep_after_world?` can decline. Measured `unlisted_live_collections=0`
   over 60 collections: the count is *always* zero, because the churned
   threads are created **during** the post-STW section, after the
   sole-mutator decision was correctly made. A check at the stop cannot see
   a thread that does not exist yet.
3. **Hold `pthread_create` while the post-STW section runs**, which is the
   one place that window can be closed from — gcry owns the hook and it runs
   on the creating thread. **35/48**, and the second arm hung, so it also
   introduces a deadlock. Withdrawn.

## What it still does not say

Which live block the sweep loses. Both release paths decide on
`counts.any_live` from `sweep_small_blocks`, so a live block's mark or
occupancy is gone by the time the chunk is judged empty — and full
conservatism says the mark was not missed by the *scan*. The bitmap
allocator publishes `occ = mark` at sweep, so a block that is live but
unmarked when the sweep reaches it loses its occupancy too. That is the next
thing to instrument.

## The harness

`make thread-churn-uaf`, three arms per layout, reporting a rate rather than
gating — the default arm fails a small fraction of runs and gating on that
would make every unrelated push flaky. What it *does* assert is that the
poisoned arm still reproduces: a reproducer that has silently stopped
reproducing is worse than none, and that is precisely how the 2026-08-23 one
was lost.
