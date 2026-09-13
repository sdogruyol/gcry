# The heap counters: the loss does not reproduce, and the atomic path is free

Date: 2026-09-13/14 (overnight) · host: AMD Ryzen AI 9 465, Linux 7.2.4 ·
tree: `ab374a4` + this change · knobs `GCRY_INVARIANT_COUNTER_LOSS=1`,
`GCRY_HEAP_COUNTERS_ATOMIC=0|1`

`ROADMAP.md` has carried this since v0.20.0, as the one open item in the
"Current" section that needed no Darwin host:

> `note_alloc_bytes` uses plain `set(get + 1)` unless `heap_counters_atomic` is
> set, and `heap.cr` calls that safe on the grounds of "single mutator + rare
> SYSMON". Measured against: with the invariant checker on,
> `spec/invariant_spec.cr` reports the process heap's `live_objects`
> **permanently one below** the walk in **3 runs of 40** [...] **Next**: decide
> the trade deliberately rather than by default.

Both halves of that trade are now numbers.

## The cost of the atomic path: not measurable

The reason it is off is a LOCK RMW on the allocation hot path. Measured with
`bench/micro/alloc_ns.cr` (48-byte `GC.malloc`, a 4096-slot live ring per
thread), arms alternating and pinned, ratio atomic/plain:

| shape | ratio | 95% CI | reading |
|---|---|---|---|
| 1 thread, 40 M allocations | 0.9836 | [0.9573, 1.0098] | no cost at this resolution |
| 4 threads, 20 M allocations | 1.0091 | [0.9877, 1.0304] | no cost at this resolution |

Both CIs span 1.0, so the cost is under about 3% and the sign is not even
determined. A Kemal `/json` A/B (`bench/counters_ab.sh`, 12 paired trials,
alternating arms, warm-up pass discarded) could not resolve it at all: ratio
0.9155 [0.8100, 1.0210], i.e. ±10% on a two-core-ish laptop under `wrk`. That
harness is kept for the record, with the caveat that end-to-end RPS is the wrong
instrument for a few-percent question on the allocation path.

## The loss it was supposed to fix: not reproducible

The v0.20.0 flake was fixed as a *scope* correction — the invariant is stated
only of a heap that keeps its counter (`Heap#counters_may_lose_updates?`), which
took `spec/invariant_spec.cr` from 6 failures in 25 runs to 0 in 60. That made
the checker honest and retired the measurement.
`GCRY_INVARIANT_COUNTER_LOSS=1` states it anyway and counts instead of raising.
The double read inside the checker still guards it: a counter that *moves*
between the two reads is a sampling race and is skipped, so what is counted is a
lost increment.

| shape | comparisons | losses |
|---|---|---|
| main + monitor only, atomic | 3 277 952 | **0** |
| main + monitor only, plain | 3 278 005 | **0** |
| 8 spawned allocators, plain | 660 649 | **0** |
| one increment dropped on purpose | caught | at every walk after it |

**4.6 million forced comparisons, zero losses**, on both counter modes. The
first attempt measured almost nothing and said so: with two spawned threads
alive, `concurrent_mutators?` skipped 406 300 walks against 1 636 comparisons —
0.4% — which is why the faithful shape is main + monitor, exactly as the
original sighting was.

The injected arm is the reason those zeros mean anything: dropping a single
increment through `debug_drift_live_objects` is caught, and caught at **every
subsequent walk**, which is the signature the roadmap named — "a lost increment
is not a sampling race, it never comes back".

## Decision

The plain counter stays the default. There is nothing measured to fix, the
escape (`GCRY_HEAP_COUNTERS_ATOMIC=1`) stays for anyone whose workload shows a
loss, and the measurement is now a gate rather than a paragraph:
`make counter-loss`, three arms, ~35 s, in CI.

What is *not* claimed: that the loss is impossible. It reproduced three times in
forty runs on the v0.20.0 tree and this says only that 4.6 M comparisons on
today's tree cannot find it — the allocation path has been rewritten twice since
(bitmap allocator, headerless layout), and the likeliest reading is that the
race was removed by one of those rather than reasoned away. The gate is what
will notice if it returns.
