# The pin block named one context type, and there are two

**Date:** 2026-08-15 · host: WSL2 x86_64, 20 CPU, Crystal 1.21.0 (`57cf7da50`),
`-Dgc_none -Dexecution_context` · tip @ `f27396a`

Earlier the same day, the Parallel pin list stopped being a list of seven names
and started being derived from `instance_vars`. The dispatch *into* that list was
still a name: `if ec.is_a?(Fiber::ExecutionContext::Parallel)`. There are two
context types on Crystal 1.21.0.

## Measured

`Fiber::ExecutionContext.includers` is `{Parallel, Isolated}`, and
`Parallel.all_subclasses` is `{Concurrent}`. With the dispatch restricted to
Parallel — the state before this change — an `Isolated` context up and running
contributes **3 pins**, all of them the ambient per-thread `@scheduler` /
`@execution_context` slots that any thread contributes. Its own ivars:

```
next, previous, name, thread, main_fiber, event_loop, exception,
mutex, condition, wait_list, spawn_context, func      → 15 pin slots
```

So `@main_fiber`, `@thread`, the wait list and **the user's `@func` closure** had
no explicit pin at all. They were reached by the conservative scan of the
Isolated object's body — which is exactly what the pin block exists because it
does not trust (Kemal EC4 SEGV @ …0008, where a layout/scan_cap truncated an
object the scan was assumed to cover).

With the dispatch derived from `includers` + `all_subclasses` instead: **18 pins,
against 15 expected** for its own slots.

Worth noting how the two 2026-08-15 findings meet here: the layout census that
morning listed `Fiber::ExecutionContext::Isolated#spawn_context` and `#func`
among the 19 ivars `Layout.register` dropped while still calling the type
precise. So under `GCRY_AUTO_LAYOUTS=1`, before that fix, an Isolated context's
closure was reachable by *neither* route — not by the precise body scan, which
omitted the slot, and not by an explicit pin, which did not exist. Neither
finding needed the other to be a defect; together they were the same object.

## The gate

`bench/scheduler_roots.cr` gained an Isolated arm that computes its expectation
from `pin_slots(Isolated)` — the same `instance_vars` the collector derives from
— so a context type added upstream fails the arm rather than passing it quietly.
Broken on purpose by restricting the dispatch back to Parallel:

```
Isolated: 3 further pins with it up (at least 15 expected for its own ivars)
FAIL: an Isolated context contributed 3 pins where 15 pointer-ivar slots are
      reachable from it — the collector's context dispatch does not cover
      Fiber::ExecutionContext::Isolated
```

Subclasses are dispatched before their parents, so a `Concurrent` is pinned with
`Concurrent.instance_vars` rather than `Parallel`'s. It adds none today; the
point is that a future one is covered without an edit.

The queue audit's dispatch is derived the same way, and asks the type whether it
has queues at all: `Isolated` has neither `@global_queue` nor `@schedulers`, so
it is skipped **for that reason** rather than by name.

## What this does not say

No crash is attributed to it. `Isolated` is opt-in — nothing in the default
runtime creates one — so this is a hole in coverage rather than a reproduction,
and the 2026-08-10 soak (plain `spawn`, i.e. the default `Parallel` context)
cannot have hit it.
