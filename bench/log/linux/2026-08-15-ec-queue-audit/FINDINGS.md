# Naming the corrupt run-queue slot at the next collection instead of at the crash

**Date:** 2026-08-15 · host: WSL2 x86_64, 20 CPU, Crystal 1.21.0 (`57cf7da50`),
`-Dgc_none` · tip @ `edba039`+

The 2026-08-10 soak died in `Parallel::Scheduler#quick_dequeue?` on
`0x7f1700000149`, 1h24m in. The dequeue is where the damage *surfaces*; the write
that caused it happened an unknown time earlier. At one crash per five hours that
gap cannot be bisected — a candidate fix and a quiet run look identical inside a
release cycle. The board named two handles for this and neither had been tried.
This is the second: instrument the slots.

## What the audit does

`GCRY_EC_QUEUE_AUDIT=1` (default off) walks, at every collection and inside the
stopped world, the two structures `quick_dequeue?` reads:

- each scheduler's `Runnables` ring, between `head` and `tail`;
- the context's `GlobalQueue` list, bounded by its own size and by a hard cap.

Every slot must be a **live Fiber**: in the heap, in an allocated block, and with
`Fiber`'s type_id at offset 0. The first collection that sees otherwise prints
the structure, the index and the value, and bumps a cumulative
`ec_queue_audit_faults` on `/gc-stats`.

Inside STW is what makes it readable: the queues are quiescent there, so a slot
that fails the test failed it *before* the world stopped rather than under the
walk.

## The default context is Parallel, so this covers ordinary programs

Measured on 1.21.0: `Fiber::ExecutionContext.default` is
`Fiber::ExecutionContext::Parallel` with or without `-Dexecution_context` and
`-Dpreview_mt`. So plain `spawn` — which is all `bench/soak.cr` uses — runs on a
Parallel context, the pin block covers it, and so does this audit. A scratch
program spawning 200 fibers per round walked **2001 ring slots over 10
collections**; with the knob off, 0.

## The gate

`bench/ec_queue_audit.cr` / `make ec-queue-audit`, four arms:

- **engagement** — the ring walk and the list walk must each see slots. A walk
  that covers nothing reports no faults and would pass every other arm.
- **healthy** — a global queue of 24 parked fibers walks 24 slots and reports 0.
- **detection** — two planted values, and the report must name *the planted one*:
  `0x7f1700000149` (outside the heap) and a live non-Fiber object (only the
  type_id check rejects that one). The corruption is manufactured where it is
  safe: the context has one worker, held inside a fiber that never yields, so
  nothing dequeues between the poke, the collection and the restore. Afterwards
  all 24 queued fibers run — a "detection" that leaves the context dead would
  prove nothing about a live one.
- **--control** — audit off: nothing walked, nothing reported.

Broken on purpose:

| broken | result |
|---|---|
| audit off (`--control`) | ring 0, list 0, both poisons unreported |
| type_id check → `true` | fault raised for `0xc0000000020`, **not** the planted value → FAIL |

That second row is why the gate asserts on `ec_queue_audit_last_fault` rather
than on the count. With the type check removed the planted live-object poison is
*accepted*, the walk follows a `list_next` read out of whatever it really points
at, and the garbage one hop later is what gets reported — a fault, at the wrong
slot, with a value nobody could trace to a write. Counting alone could not tell
those apart.

## Cost, and the limit of what it buys today

Pause p50 over the 25 s soak, n=3 per arm: **off 2.66 / 2.76 / 2.81 ms, on 2.51 /
2.65 / 2.50 ms**. No measurable cost — which is less impressive than it sounds,
and the telemetry says why: the soak's `queue_slots` column reads **0–1 per
collection**. It spawns fibers at ~10 Hz against roughly one collection per
second, so the queues are almost always empty when the world stops.

So the honest statement of what this buys on the *current* soak is narrow: it
catches a corrupt slot only if a collection lands while that slot is inside
`head..tail`. It is not thin coverage of the mechanism — the mechanism is gated
and proven — it is thin *exposure* of the workload.

The obvious next step is therefore not more instrument but more traffic: a fiber
churn knob on the soak that keeps the run queues populated, so a collection has
something to look at. That changes the soak's shape and with it the baseline for
the open SEGV, so it is left as the next step rather than folded in here.
`ec_queue_audit` is on for the CI soak either way (`workflow_dispatch` input
`ec_queue_audit`), and the telemetry now carries `queue_slots` and
`queue_faults` per hour, so a crashing run says which hour the slot went bad
instead of only that it did.

---

## Follow-up, same day: the walk could not report a reissued *container*

The audit above validates queue **slots**. The standing reading of the SEGV is a
block freed and reused while the scheduler still pointed at it — and the object
that *holds* the slots can be reissued exactly the same way. In that case the
slot walk reads a head, a tail and a ring out of whatever the block became, and
reports nothing useful: everything it finds is garbage rather than a slot that
stopped being a Fiber.

`audit_ec_structs` now checks, for every ivar whose declared type is a concrete
Reference class, that the referent is a **live object of that type** (heap +
allocated + exact type_id). Abstract and module-typed ivars
(`@event_loop : Crystal::EventLoop`) are skipped rather than guessed at: the
runtime type is a subclass and there is no single id to compare against. Derived
from `instance_vars`, like the pins.

Two things the first run taught, both now in the code:

- **Outside the heap is not a fault.** Every context's `@name` is a `String`
  literal living in the program image, so `is_heap_ptr` is false for it — the
  first run reported `Parallel@name` as corrupt on every collection. gcry never
  sweeps what it did not allocate, so a non-heap referent is out of this check's
  scope. That is also its limit, and it is worth stating: a wild pointer that
  lands outside the heap passes here.
- **A container that fails identity must not then be walked.** The first run
  reported the planted `@runnables` correctly and then walked the decoy as if it
  were a 256-slot ring, burying that line under 255 garbage slot faults (2 → 257).
  The walks are now gated on the container's identity, which is what the report
  line ("the walk below cannot be trusted") already claimed.

Gated by a fifth arm in `make ec-queue-audit`: a scheduler's `@runnables` is
pointed at a live object of the wrong type, and the report must name **that**
value. Broken on purpose — with the identity check compiled out:

```
FAIL: a scheduler whose @runnables is a live object of the wrong type was
      collected over without a word — the audit checks the slots and not the
      structure that holds them
```

Silent on healthy processes: 0 faults across the gate's own churn context, its
one-worker context, and a 15 s soak at `--fiber-churn=128` (388 slots walked, 6
of 14 collections non-empty).
