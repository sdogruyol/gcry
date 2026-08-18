# The pin list was seven names; the structures are nineteen slots

**Date:** 2026-08-15 · host: WSL2 x86_64, 20 CPU, Crystal 1.21.0 (`57cf7da50`),
`-Dgc_none -Dexecution_context` · tip @ `edba039`

`ec_root_pins` (f396fc4) answered "did the Parallel pin block run". It could not
answer the question the v0.20.0 item actually turns on: *is the list of things it
pins complete?* Nothing compared the block's seven names against the structures'
ivars, so a queue added upstream would be missed exactly the way Darwin's empty
`each_thread_greg` was.

## What the list was missing

The block pinned `@global_queue`, `@event_loop`, `@stack_pool`, `@schedulers`,
and per scheduler the scheduler itself, `@runnables` and `@main_fiber`. The
pointer-bearing ivars actually present on Crystal 1.21.0:

```
Fiber::ExecutionContext::Parallel        Parallel::Scheduler
  next        (ExecutionContext | Nil)     name              String
  previous    (ExecutionContext | Nil)     execution_context Parallel
  name        String                       thread            (Thread | Nil)
  mutex       Thread::Mutex                main_fiber        Fiber          ✓
  condition   Thread::ConditionVariable    global_queue      GlobalQueue
  global_queue GlobalQueue        ✓        runnables         Runnables(256) ✓
  stack_pool  Fiber::StackPool    ✓        event_loop        Crystal::EventLoop
  event_loop  Crystal::EventLoop  ✓
  schedulers  Array(Scheduler)    ✓
  rng         Random::PCG32
```

Four of ten on the context, three of seven on the scheduler. The others were
covered only by the conservative body scan — which is precisely what the pin
block exists because it did not trust (Kemal EC4 SEGV @ …0008, when a
layout/scan_cap truncated the object).

## Deriving the pins instead of listing them

`pin_ec_ivars(obj, type)` walks `type.instance_vars` at compile time and marks
every ivar that can hold a pointer. A list drifts; `instance_vars` cannot.
Measured, one 4-worker context: **12 slots on the context + 7 per scheduler**,
so 45 named slots per collection against the 16 the seven names produced.

Two things this turned up that a name list would have hidden:

**`@next` and `@previous` are two words, not one.** `sizeof(Fiber::ExecutionContext | Nil)`
is **16** on 1.21.0 — a module union carries a type_id word beside the pointer.
An implementation that "pinned the pointer word" would have pinned the type_id
and looked covered. So anything not plainly a `Reference` gets **every word** of
its slot marked rather than a guessed one, which also covers `Proc` and `Tuple`
shapes if upstream adds them.

**A nil ivar and an ivar nobody looked at were indistinguishable.**
`mark_ref_slot` counted after its `return if bits == 0`, so a context with a nil
`@thread` counted the same as a block that never visited the slot. The counter
now counts the *slot*, not the mark, and the gate's expectation is exact:
`1 + slots(Parallel) + n × (1 + slots(Scheduler))`.

## The gate

`bench/scheduler_roots.cr` computes that expectation from `instance_vars` too —
the same place the collector derives the pins from — so an upstream addition
raises both sides together instead of leaving a hardcoded "4 and 3" behind.
Measured delta **51–53 against a floor of 45** (the excess is the ambient
per-thread `@scheduler` / `@execution_context` pins that the context's four
worker threads add; the floor is what the block itself owes).

The residue is one counter: `ec_root_unpinned_ivars`, for a pointer-bearing ivar
*narrower* than a pointer, which has no sound single answer. Zero on 1.21.0, and
asserted zero rather than assumed.

Both arms broken on purpose and observed red:

| broken | result |
|---|---|
| `pin_ec_ivars` stubbed to emit nothing | delta 11 against 45 → FAIL |
| `bytes < word` widened to `<=` | 5 unpinned ivars → FAIL |

`--control` (no context) still holds the delta at exactly 0, so the arm is not
vacuous in the other direction. 8/8 green runs after the change; `spec`,
`process_spec`, `make invariants`, `greg-roots`, `ivar-layout-roots` and
`stw-mt-property-test-short` unaffected.

## What this does *not* say

It does not explain the 2026-08-10 soak SEGV. The soak runs without
`GCRY_AUTO_LAYOUTS`, so its EC objects were scanned conservatively end to end and
the six ivars the old list omitted were covered by that scan anyway. What changes
is that they no longer *depend* on it — which is the whole reason the pin block
exists.
