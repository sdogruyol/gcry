# Phase 7.4 — the finalizer index costs 9.5% on the free path

Date: 2026-09-03 · host: WSL2, AMD Ryzen AI 9 HX 375 · branch `simdgc-headerless`
Free-heavy loop (20 000 frees of unregistered objects) with a 5 000-entry
finalizer table — the exact shape `notice_reclaim`'s comment cites at ~15%+ CPU
on HTTP apps. Paired interleaved n=12.

## What changed

`BlockHeader::Flags::FINALIZER` and `DISAPPEARING` guarded `notice_reclaim`'s
linear scan of the finalizer tables. Both bits must leave the header for
headerless, and they cannot simply be dropped — without a guard every ordinary
free scans thousands of unrelated entries. They are replaced by an O(1)
registration index (open addressing, refcounted per object, LibC malloc).

## Result: a real, small regression

| | ns per free |
|---|---|
| header flags (before) | 47.0 |
| registration index (after) | 51.5 |
| **diff** | **+4.5 ns, +9.5%, t=4.44** |

I expected parity and did not get it, and the reason is obvious in hindsight:
the flag was a bit in the object's **own header**, already in cache because the
block is being freed. The index is a probe into a **separate table** and pays a
cache miss. Both are O(1); only one is free.

An earlier version of the code comment claimed the index was "strictly better
than the flags it replaces". That was wrong and is corrected — it is better only
for objects that *do* have a registration (it skips the O(n) scan the flags
never avoided), and those are the rare case.

## Why keep it

The bits have to go for Phase 7 to exist at all, and this is the cheapest
correct guard found. The refcount matters: an object can carry both a finalizer
entry and a disappearing link, which two independent flag bits expressed
naturally and a presence-only set would get wrong — removing one registration
would hide the other. `spec/finalizer_index_spec.cr` pins that case.

## Running total for Phase 7

The phase is accumulating costs ahead of its payoff, which is expected but worth
tracking honestly in one place:

| step | cost so far |
|---|---|
| 7.2 chunk kinds | **+7.9% RSS** |
| 7.4 finalizer index | **+9.5% free path** |

Neither buys anything yet. Both are paid back only at 7.7, when the header is
removed and every object returns 16 bytes. The bar the payoff must clear keeps
rising, and that is the number to keep in view.
