# Phase 7.2 — chunk kinds cost 7.9% RSS, and that is the expected shape

Date: 2026-09-03 · host: WSL2, AMD Ryzen AI 9 HX 375 · branch `simdgc-headerless`
Kemal `/json`, paired interleaved n=7, both arms `GCRY_BITMAP_ALLOC=1`.

## What changed

`ATOMIC` moves from the block header to a **chunk kind**: atomic and pointerful
blocks are allocated from separate chunks. The pool cursor is now per
(size class, kind) — pointerful at `class`, atomic at `class + SIZE_CLASS_COUNT`
— and `bitmap_take_pool_chunk` refuses a chunk of the wrong kind.

## Why kinds and not a per-block atomic bitmap

A third per-chunk bitmap alongside `occ` and `mark` looks simpler and avoids
fragmentation entirely. It was rejected because it needs **a store on every
allocation**: a reused block may have been atomic under its previous occupant,
so the bit must be cleared even for the pointerful case. Per-allocation
accounting to enable a skip is precisely the failure that rejected
`2026-08-01-ec4-alloc-bits` ("accounting that enables skip is not free on the
HTTP alloc path"). A chunk kind is fixed at map time and costs the mutator
nothing.

## Result

| metric | kinds | base (`simdgc`) | diff | t |
|---|---|---|---|---|
| `/json` rps | 34750 | 34333 | −2.1% | −0.62 (n.s.) |
| post-GC RSS | 13968 kB | 13108 kB | **+7.9%** | **8.86** |

Throughput is unaffected, which is the point of choosing kinds over a bitmap.
**RSS regresses 7.9%**, and that was the predicted risk: a size class that sees
both kinds now needs two chunks where it needed one, so the tail chunk of every
(class, kind) pair is partially filled instead of one per class.

## Read this correctly

7.2 is a **prerequisite with a cost and no benefit yet**. The benefit arrives
only at 7.7, when the header is actually removed and every object gets 16 bytes
back — 50% of a class-0 block. Until then Phase 7 is strictly negative on the
axis it exists to improve.

The consequence for planning is worth stating: **a partial Phase 7 must not
ship.** There is no useful intermediate state to land; the phase either reaches
7.7 or it is reverted. That is an argument for keeping it on its own branch
until the whole staircase is climbed, which is how it is set up.

The +7.9% also sets the bar the payoff has to clear. Headerless must return more
than it, which on a class-0-heavy mix it should comfortably do, but that is now
a number to beat rather than an assumption.
