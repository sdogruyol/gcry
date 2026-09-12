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

## What it does not say, stated because it would be easy to overclaim

**The ordering is ambiguous.** A run that fails has usually raised something
first — the sibling log's `pthread_mutex_unlock: Invalid argument` — and
Crystal's backtrace printer then allocates hundreds of kilobytes of DWARF
tables and `Array(String)`. So the released large object may be the
printer's buffer, i.e. a *second* symptom downstream of whatever raised, not
the primary defect. Distinguishing them needs a sighting with no prior
exception, and this harness does not yet isolate one.

**The missing root is a stack slot or a register**, which is what the holders
search says and all it says. The standing first suspect from 2026-08-23 is
unchanged: `GC.realloc` growth, where between `realloc` returning a new
large block and the caller storing it the only reference is a register.

## The harness

`make thread-churn-uaf`, three arms per layout, reporting a rate rather than
gating — the default arm fails a small fraction of runs and gating on that
would make every unrelated push flaky. What it *does* assert is that the
poisoned arm still reproduces: a reproducer that has silently stopped
reproducing is worse than none, and that is precisely how the 2026-08-23 one
was lost.
