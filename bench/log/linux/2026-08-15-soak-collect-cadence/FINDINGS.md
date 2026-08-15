# The other factor in the soak's catch rate, and it was hardcoded

**Date:** 2026-08-15 · host: WSL2 x86_64, Crystal 1.22.0-dev · `bench/soak.cr`
`--fiber-churn=128`, 120 s arms, run sequentially so no arm competes with another

`GCRY_EC_QUEUE_AUDIT` can only report a slot that is corrupt **while a collection
is looking at it**. So the rate at which a soak could catch a fault is a product:

    chances  =  collections  x  occupancy

`--fiber-churn` was built for the second factor and moved it from 1-in-24
collections to 23-in-24. The first factor was never touched. It sat in
`bench/soak.cr` as `sleep(1.seconds)` — a hardcoded 1 Hz, comment and all.

## `GCRY_THRESHOLD` does not move it

The obvious lever is the allocator's major threshold, so that was measured first,
120 s per arm:

| `GCRY_THRESHOLD` | collections in 120 s |
|---|---|
| default (32 MiB) | 118 |
| 8 MiB | 119 |
| 2 MiB | 119 |

Flat, because these collections are not the allocator's. They are the harness's
own timer fiber calling `GC.collect`, and the workload never allocates its way to
32 MiB between ticks. The knob to add was on the harness, not on the heap.

## What `--collect-hz` buys, and what it costs

| `--collect-hz` | collections | non-empty | slots walked | pause p50 | allocs | max RSS |
|---|---|---|---|---|---|---|
| **1** (baseline) | 118 | 56 (47%) | 5 377 | 2.04 ms | 117 740 | 30 424 kB |
| **5** | 587 | 286 (49%) | 23 643 | 1.90 ms | 117 380 | 13 600 kB |
| **20** | 2 262 | 984 (43%) | 88 579 | 1.84 ms | 113 140 | 10 820 kB |

**16× the slot walks for 4% of the workload**, and three things that could have
gone wrong did not:

- **Occupancy does not dilute.** 47% → 49% → 43%: collecting more often does not
  mean catching emptier queues, so the product really does scale with the factor.
- **The pause does not grow — it shrinks.** 2.04 → 1.84 ms p50. Each collection
  has less garbage in front of it, which is the same reason max RSS falls from
  30.4 MB to 10.8 MB.
- **The workload survives.** 117 740 → 113 140 allocations, −3.9%.

## What this does not claim

It raises the rate at which a corrupt slot could be **seen**, not the rate at
which one is **created**. If the corruption is time-driven, a run finds it sooner
because it looks more often; if it is collection-driven, more collections also
means more chances to cause it — either way the run is a better instrument, but
neither is evidence about the defect, and no fault was reproduced here.

The 43–49% occupancy above is `--fiber-churn=128`, not the 23-in-24 that
`--fiber-churn=512` measured on this host — the arms here were about cadence, and
holding churn fixed is what makes the three rows comparable.

Default is **1**, the cadence every earlier soak ran on and the one the open
2026-08-10 SEGV is measured against. `--collect-hz=0` is refused rather than
divided by.
