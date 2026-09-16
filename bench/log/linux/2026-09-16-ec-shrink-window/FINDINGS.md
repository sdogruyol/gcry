# The one EC window whose coverage is conservative-only: `Parallel#resize` shrinking

**Date:** 2026-09-16 · host: AMD Ryzen AI 9 465 (Zen 5, 20 threads), Linux 7.2.4
Tree `92afb3a` · Crystal 1.21.0 · `bench/scheduler_roots.cr --resize`

The EC pin audit was complete by construction as of 2026-08-15: `pin_ec_ivars`
derives its pins from `instance_vars`, the dispatch runs over
`Fiber::ExecutionContext.includers` + subclasses, and `ec_root_unpinned_ivars` is
asserted zero. What that construction covers is the context **as the context
lists it**. This is the audit of the one state where the list and reality differ.

## The window

`Fiber::ExecutionContext::Parallel#resize` does not mutate `@schedulers` — it
replaces it, deliberately, so a concurrent `#steal` that dereferenced the array
once keeps reading a valid one (stdlib comment, `parallel.cr:201`). On a shrink:

    removed_schedulers = old_schedulers[new_capacity..]
    removed_schedulers.each(&.shutdown!)
    @schedulers = old_schedulers[0...new_capacity]

and the shutdown is **cooperative** — stdlib, `parallel.cr:193`: *"running
schedulers won't stop until their current fiber tries to switch to another
fiber."* So between the replacement and the worker actually stopping, a
`Scheduler` is being run by a live thread while the context no longer lists it.

gcry's pin block walks `ec.@schedulers` (`collect_scan.cr:415`) — the new array.
So every named pin those schedulers had is gone for the duration of the window.

## Measured

`--resize` builds a 4-worker context, holds one **non-yielding** fiber per worker
so the cooperative shutdown cannot complete, shrinks to 1, and collects:

| | before shrink | after `resize(1)` |
|---|---|---|
| `ec.@schedulers.size` | 4 | 1 |
| `ec_root_pins` delta | 53 | 29 |
| removed schedulers with a live thread still pointing at them | — | **3 of 3** |
| removed schedulers / `@runnables` / `@main_fiber` swept | — | **0** |

**24 named pins are dropped**, which is exactly `3 × (1 object + 7 ivars)` —
derived from `pin_slots(Scheduler)` on the harness side and from `instance_vars`
on the collector side, so the number moves with upstream instead of being written
down. That quantity is what the arm gates on.

The first version of the arm parked its fibers instead of spinning them and
measured **0 of 3** removed schedulers still having a reader: every removed
worker had already stopped before the collection could look. A green from that is
worth nothing, so the arm now fails if the window is not open.

## Nothing is lost — and not because anything names it

The survival checks pass. They also pass with the naming deleted. Positive
control, `mark_ref_slot(pointerof(thread.@scheduler)…)` removed from
`scan_thread_roots`:

| build | ambient pins | pins with context | removed schedulers swept |
|---|---|---|---|
| tip | 25 | 78 | 0 of 3 |
| `thread.@scheduler` pin deleted | 23 | 72 | **0 of 3** |

So what retains a removed scheduler in that window is not a named pin. It is the
conservative scan of the `Thread` object's body plus the running worker's own
stack and registers — which is precisely the coverage the pin block exists
because it does not trust: it was introduced after a Kemal EC4 SEGV at `…0008`
that the `Thread` body scan did not prevent, when `layout` / `scan_cap`
truncated the object.

The second positive control, the pin loop itself removed, does fire:
`named pins the shrink dropped: 0 … where 24 are derivable` — red, exit 1. So the
arm discriminates on the quantity it claims to measure, and does not claim to
discriminate on survival.

## What this does and does not say

- **No defect.** Nothing is swept, on this host, in this window.
- **The coverage in that window is conservative-only**, and the project has one
  measured instance of that class of coverage being insufficient.
- **It is latent.** Nothing in this tree shrinks a context: `--workers` (added
  2026-09-16) and `bench/kemal/src/server.cr` both resize once at startup, which
  only grows. The window is reachable by any caller that shrinks, and it is now
  under a gate on all three platforms that run `make scheduler-roots`.
- **It does not explain the 2026-08-10 soak SEGV.** Nothing called `resize` at
  all then, so this window was never entered. The item it belongs to stays open
  for the same reason as before.

The cheap way to make the window named rather than conservative would be to pin
the ivars of `thread.@scheduler` in the per-thread block, not only those of the
schedulers the context lists. That is a real change to the pin budget (seven more
slots per thread per collection) for a path nothing reaches today, so it is
recorded here rather than made.
