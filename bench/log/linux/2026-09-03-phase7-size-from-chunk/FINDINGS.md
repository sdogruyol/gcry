# Phase 7.6 — size from the chunk costs 7.1% of the mark, and the plan's
# decision 5 was wrong

Date: 2026-09-03 · host: WSL2 · branch `simdgc-headerless`
`bench/micro/gc_phases --shuffle --fanout=6`, paired interleaved, vs `simdgc`.

## What had to change

`header.value.size` is the last header field with no alternative source. It is
replaced by `Heap#block_payload`, which derives the same number from the chunk —
size class for a small block, mapping extent for a large one. It derives from
the chunk **in the header build too**, so every converted site is
behaviour-preserving today and `spec/block_payload_spec.cr` pins that the two
sources agree for every allocated block across every class and both kinds. That
agreement is the whole correctness argument for deleting the header.

## Decision 5 was measured and is wrong

The plan said to carry the chunk on the mark stack so `scan_object` would not
re-resolve it — "killing the second `chunk_containing`". Implemented and
measured, that is the **worst** of the three options:

| design | phase_mark vs `simdgc` | t |
|---|---|---|
| 2-word stack (header + chunk), size from chunk | **+15.5%** | 20.09 |
| 2-word stack, size still from header | +13.4% | 62.89 |
| **1-word stack, chunk via lookup, radix off** | +8.6% | 12.00 |
| **1-word stack, chunk via lookup, radix on** | **+7.1%** | 9.07 |

The attribution is unambiguous: **+13.4% of it is the stack doubling alone**,
before the chunk is used for anything. The mark stack is hot and its *width*
costs more than the lookup it was meant to avoid. Deriving size from the chunk
adds only ~2pp on top.

So the design went the other way from the plan: keep the one-word stack and pay
an O(1) radix lookup. `mark.cr` carries the measurement inline so the next
person does not re-try the two-word stack.

## The cost is inherent, not an implementation flaw

+7.1% on `phase_mark` is, near enough, handing back the −7.7% that 778b956
earned — because that win *was* removing this exact per-object lookup. Any
headerless build must source the size from somewhere other than the object, and
on this workload that costs about what it saved. It is the price of the phase,
not a bug in this attempt.

## Phase 7 running cost

| step | cost | on what |
|---|---|---|
| 7.2 chunk kinds | +7.9% RSS | workloads mixing atomic + pointerful (Kemal does) |
| 7.4 finalizer index | +9.5% | free path |
| 7.6 size from chunk | +7.1% | `phase_mark` |

Against a payoff of `live_objects × 16 B`: **44% of heap** on a class-0-dense
workload, 9.1% at 64 B, **0.1% on Kemal**.

Net, for the two regimes that matter:

- **class-0-dense:** +44% RSS against −7.9% RSS and two throughput costs. Still
  clearly worth it on an RSS-constrained workload.
- **Kemal-shaped:** +0.1% RSS against −7.9% RSS, −7.1% mark, −9.5% free. Bad,
  and getting worse with each step.

The phase continues toward 7.7 to measure the payoff rather than infer it, but
the shape of the answer is now visible and it is a **workload-conditional win**,
not a general one.
