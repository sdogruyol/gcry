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

**16× the slot walks for 4% of the workload** over 120 s here — and the 5 h CI
arms then said that number does not hold. See the correction below before using
it. What did hold:

- **The pause does not grow — it shrinks.** 2.04 → 1.84 ms p50. Each collection
  has less garbage in front of it, which is the same reason max RSS falls from
  30.4 MB to 10.8 MB.
- **The workload survives** at this duration: 117 740 → 113 140 allocations,
  −3.9%.

Read at 120 s, occupancy looked flat (47% → 49% → 43%), and this file originally
concluded from that that "occupancy does not dilute, so the product really does
scale with the factor". That conclusion was wrong.

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


## Correction: at 5 h on CI, occupancy dilutes and the gain is 2.6x

Two `workflow_dispatch` runs, three 5 h arms each, `--fiber-churn=128`,
identical in every input but the cadence:

| | collections | non-empty | slots walked | faults |
|---|---|---|---|---|
| **1 Hz** (31880856352) | 52 469 | 12 674 (**24.2%**) | 710 307 | 0 |
| **20 Hz** (31886802497) | 768 550 | 26 146 (**3.4%**) | 1 818 412 | 0 |
| ratio | **x14.6** | | **x2.56** | |

Collections scaled as expected. Occupancy did not hold: it fell by 7x, because
collecting 20x more often leaves 20x less time for fibers to pile into a run
queue before the world stops. The two factors are not independent — raising one
eats the other — so the knob is worth **2.6x more slot walks**, not the 16x the
120 s arms projected.

The workload cost is also larger at 5 h than at 120 s: 17.4 M allocations per
control arm against 10.4-15.1 M at 20 Hz, so -13% to -40% rather than -3.9%.
Between-arm spread is wide on both sides (207 k to 301 k collections; 212 k to
1.04 M slots), which is its own reason not to read a single arm as a measurement.

**Why the short run misled.** At 120 s the process is still filling: churn is
ramping, the heap has not reached steady state, and the queues carry a backlog
that a faster cadence can still find. At 5 h the workload is in equilibrium and
the cadence competes directly with the fibers' arrival rate. A cadence knob has
to be measured at the duration it will run at.

2.6x is still 2.6x, and the pause and RSS gains are real, so the knob keeps its
place — but the number to quote is 2.6, and the default stays 1.