# Phase 7's payoff, measured before finishing it

Date: 2026-09-03 · host: WSL2 · branch `simdgc-headerless`

Phase 7 has been accruing cost (7.2: +7.9% RSS, 7.4: +9.5% free path) against a
payoff assumed rather than measured. Before spending the hard steps (7.6/7.7,
the 207-site header removal), here is the ceiling — `live_objects × 16 B` as a
fraction of the heap, which is the most headerless can ever return.

## The ceiling depends entirely on the workload

| workload | live objects | header bytes | % of heap | % of RSS |
|---|---|---|---|---|
| **Kemal `/json`** (post-GC) | 1 002 | 16 KB | **0.1%** | ~0.1% |
| dense, 64 B payload | 502 145 | 7.7 MiB | 9.1% | 8.5% |
| dense, **16 B payload** (class 0) | 1 540 508 | 23.5 MiB | **44.4%** | **40.0%** |

Set against the cost already booked (+7.9% RSS from chunk kinds, paid on every
workload):

- **class-0-dense: +40% back for −7.9% paid.** Decisively worth it.
- **64 B-dense: +8.5% back for −7.9% paid.** Roughly break-even.
- **Kemal: +0.1% back for −7.9% paid.** A clear net loss.

## What this does and does not say

It does **not** invalidate Phase 7. The plan always aimed it at "the fat app",
not Kemal — "This is the phase that targets RSS × Boehm < 1.0 on the fat app
without stack maps", with acik named as the instrument. This is the first time
that targeting has been *quantified*, and it turns out to be sharper than
expected: the phase is close to worthless on a heap with few live objects and
transformative on one with many small ones. Object **count** and object **size**
both matter, and Kemal has little of either.

It does say something uncomfortable about validating the work here: **the costs
are measurable on the instrument available and the benefit is not.** Kemal is
the only end-to-end workload on this box, and on Kemal Phase 7 can only lose.

## The measurement plan that follows from it

The instruments split, and that is workable:

- **`bench/micro/gc_phases --size=2`** (1.5 M live 16 B objects) is the **payoff
  instrument**, with a 40% RSS ceiling to measure against. The payoff *is*
  measurable here — just not through Kemal.
- **Kemal** stays the **regression guard**: it cannot show the win, so its only
  job is to prove the phase does not make a sparse-heap workload worse.

Stating both before 7.7 lands means the result can be reported as hit or miss
rather than rationalised afterwards.

## Recommendation

Continue, but with the target restated: Phase 7 is a **small-object-density**
optimisation, not a general RSS win, and it must be judged on a dense heap. If
the eventual measurement on `gc_phases --size=2` does not return well above the
+7.9% already paid, the phase should be reverted rather than shipped — and on
Kemal-shaped workloads it should stay off regardless of how the dense case goes.
