# Making the next crash unarguable

**Date:** 2026-08-15 · host: WSL2 x86_64, 20 CPU, Crystal 1.21.0 (`57cf7da50`),
`-Dgc_none` · tip @ `f27396a`+

The 2026-08-10 soak died in `Parallel::Scheduler#quick_dequeue?` on
`0x7f1700000149`. Three sessions have now argued about what that value was — a
pointer with its low bytes overwritten, a reissued object's first two `Int32`s
(`{329, 32535}`), a valid pointer into a chunk that had been unmapped. The
argument cannot be settled, and the reason is not that anyone reasoned badly: the
value is **plausible**. Every reading fits.

`GCRY_POISON_FREED=1` removes plausibility from the next one. A freed block's
payload becomes `0xdeadf2eedeadf2ee`, which is not a pointer, not zero, not
anyone's data, and — being non-canonical on x86_64 — faults the instant it is
dereferenced, at an address that reads as a sentence.

## Where it hooks

Every small used→free transition funnels through `Heap#push_size_class_free`:
`GC.free` reaches it directly, and the sweep reaches it through `reclaim_small`
and through `freelist_reserve_fully_dead` → `link_small_to_freelist`. One hook
covers all three. Large blocks have their own site and are poisoned there;
`poisoned_blocks` on `/gc-stats` counts both.

It is sound because the freelist link lives in the block **header**
(`next_free`), not in the payload, so nothing the collector reads afterwards is
in the poisoned range.

## The half that could have broken the collector

gcry skips the clearing memset in `malloc` when a size class's freelist is known
clean — a freshly carved chunk is zero, so there is nothing to clear. Poisoning a
block on a list still marked clean would hand `0xdeadf2ee…` to a caller that
asked for zeros. That is not a debugging aid, it is a corruption.

The pairing that prevents it: every path into `push_size_class_free` sets
`@freelist_clean[class] = false`. `bench/poison_freed.cr`'s second arm is what
proves the pairing rather than asserting it — 64 blocks freed and 64 allocated
back per class, every word checked. Broken on purpose by deleting the one line
that clears the flag:

```
cleared allocations: 10560 non-zero words of 10560
FAIL: the freelist-clean fast path handed out a poisoned block, which is a
      correctness regression and not a debugging aid
```

## Measured

With the knob on: 5/5 freed payloads read the pattern, a word read out of a freed
block returns `0xdeadf2eedeadf2ee` instead of what was written there, and cleared
allocations come back **0 non-zero words of 10560**. With it off: 0/5 poisoned,
the stale read returns the marker that was written, `poisoned_blocks` 0.

Cost, soak pause p50, n=5 per arm:

| | p50 (ms) | median |
|---|---|---|
| off | 3.72, 2.95, 2.64, 2.72, 2.62 | **2.72** |
| on | 4.28, 3.56, 4.26, 3.05, 3.81 | **3.81** |

**~+1.1 ms on a ~2.7 ms pause, about +40%.** That is what a memset per freed
block costs inside the sweep, and it is why the default is off and why the soak
job is where it gets turned on. Unlike the queue audit — whose cost stayed under
the noise floor even at 500 slots per collection — this one is visible, so it is
quoted rather than waved at.

## What it does not do

It does not find the bug. It makes the *next* occurrence say what it is: a crash
on `0xdeadf2ee…` is a use-after-free and nothing else, and a crash on some other
plausible value is not one. Either answer forecloses a reading that is currently
open, which is more than the last four crashes managed between them.
