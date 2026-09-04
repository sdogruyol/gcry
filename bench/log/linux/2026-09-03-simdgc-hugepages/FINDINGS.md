# GCRY_HUGEPAGES is inert without a reserved arena — measured

Date: 2026-09-03 · host: WSL2, AMD Ryzen AI 9 HX 375 · `simdgc`
`bench/micro/gc_phases --shuffle --fanout=6`, paired n=12, `GCRY_BITMAP_ALLOC=1`.

## Expectation, stated before measuring

The plan (Phase 8) predicted **mark −20%, alloc −15%, against a probable RSS
cost**, and asked for both axes recorded and the knob left off by default.

## Result: nothing moved, on any axis

| metric | THP on | default | diff | t |
|---|---|---|---|---|
| `phase_mark` | 12011 µs | 11950 µs | +0.5% | +1.82 |
| `ns_per_alloc` | 129.2 ns | 128.9 ns | +0.2% | +0.95 |
| RSS | 63639 kB | 66524 kB | −4.3% | −1.01 (n.s.) |

A miss, and not a marginal one — the predicted −20% mark is absent entirely.

## Why, and why this is worth knowing

`MADV_HUGEPAGE` on a gcry chunk **cannot** be honoured. Chunks are 128 KiB and
each is its own `mmap`, while transparent huge pages back a ≥2 MiB naturally
aligned region *within a single VMA*. A 128 KiB VMA is an order of magnitude too
small to ever receive one, so the advice is accepted by the kernel and then has
no effect. The measurement is what a no-op looks like.

This reframes the plan's wording. "Reserved arena + `MADV_HUGEPAGE`" reads like
two independent pieces of work; it is in fact **one prerequisite and one
mechanism**. Without a large contiguous arena to carve chunks from, the madvise
half is unreachable — so there is no cheap version of this item, and any future
attempt that skips the arena will reproduce this null result.

The RSS −4.3% is not significant (t=−1.01, 7/12) and, given the advice cannot
take effect, is noise rather than a THP effect. Notably the *expected* direction
was RSS **worse**; seeing it drift the other way is further evidence nothing
happened.

## Standing

The knob ships off, documented as a no-op pending the arena, and kept because it
is the correct mechanism and the landing site for the arena work — not because
it currently buys anything. The honest state of Phase 8's hugepages item is
**not done**: the arena is the work, and it is a chunk-allocator restructure.
