# Darwin: a process with more than 64 threads loses them on the first collection

**Date:** 2026-09-17 · Darwin runner (macOS, Apple Silicon, GitHub-hosted) and
AMD Ryzen AI 9 465 / Linux 7.2.4 · Crystal 1.21.0 · tree `6171a30`
`bench/thread_startup_cost.cr`

The probe was built for a slowness observation. It found a hang, and the hang
has a cause in `src/`.

## What the probe measured

`us/thread` and `ready_ms` over n = 8/32/64/100, three arms, each (arm, n) pair
its own bounded child at 120 s.

| arm | n=8 | n=32 | n=64 | n=100 | collections |
|---|---|---|---|---|---|
| Darwin auto=off | 9.2 ms | 8.4 ms | 6.9 ms | **2.3 ms** | 0 |
| Darwin auto=on | 7.8 ms | 8.0 ms | 3.5 ms | 10.9 ms | 0 |
| Darwin collect | 7.6 ms | 32.3 ms | **TIMEOUT** | **TIMEOUT** | 10, 7 |
| Linux collect | 31.6 ms | 65.1 ms | 41.3 ms | 85.7 ms | 12, 12, 12, 11 |

Two readings, and the first kills the original hypothesis:

- **Thread startup on Darwin is not slow.** 100 threads reach running in
  **2.3 ms** with collections off — the same order as Linux's 2.8 ms. The
  120 s that `stack_bounds_growth` spent was never thread creation.
- **A collection during the storm is what hangs it, and it hangs at 64.** n=32
  completes in 32.3 ms; n=64 and n=100 exceed 120 s. That is not a curve, it is
  a cliff, and it sits exactly on a constant in the Darwin stop-the-world.

## The constant

`src/gcry/platform/darwin_stw.cr`:

    MAX_STW_SP_SLOTS = 64

…backs the SP table, the greg table, the id table and the Mach port table.
`stop_world_threads` suspends **every** thread in the list:

    kr = LibMach.thread_suspend(port)
    ...
    if @@stw_port_count < MAX_STW_SP_SLOTS
      @@stw_ports[@@stw_port_count] = port
      @@stw_port_count += 1
    end

and `resume_suspended_ports` resumes **only what the table holds**.

### Defect 1 — threads past the 64th are suspended and never resumed

The suspend is unconditional; the record is not. A process with more than 64
threads besides the collecting one leaves every thread past the 64th
permanently suspended on its first collection. That is the hang: the probe's
threads never reach `running`, so the child waits out its whole budget. It is
also what took the Darwin job down through `stack_bounds_growth` at 100
threads on 2026-09-16 — the same cliff, found by a harness that was asking
about something else.

### Defect 2 — and their roots are never scanned

`slot_for` returns −1 past the table (`return -1 if i >= MAX_STW_SP_SLOTS`), so
`record_thread_sp` and `record_thread_gregs` return early. Those threads are
suspended with **no SP captured and no registers captured**, so the clamped
stack scan and `each_thread_greg` have nothing for them. A reference live only
in the 65th thread's registers, or below its saved SP, is not a root.

That is the v0.19.0 shape on a new axis: `each_thread_greg` yielding nothing
for a thread whose registers the collector nonetheless believes it covered.
Defect 1 masks it in practice — a permanently suspended thread stops producing
new references — but the first collection that crosses the bound scans the
64 it recorded and sweeps against a world it has only partly read.

## What is not claimed

- **No user-visible sighting.** Every observation here is from harnesses asking
  for ≥64 threads on purpose. Whether any real Crystal program on Darwin runs
  more than 64 OS threads is not measured; `Fiber::ExecutionContext::Parallel`
  defaults to capacity 1 and grows to the CPU count, so a plain program would
  need an unusual thread count to reach it.
- **The 64 bound is not obviously wrong on Linux**, which uses a signal
  broadcast and a growing bounds table; the cliff is specific to this file.
- Defect 2 has not been demonstrated collecting a live object. It is read off
  the code path, with the counters to prove it not yet wired.

## The fix has two halves and they are not equally safe

1. **Resume must not depend on the table.** `start_world_threads` already walks
   `Thread.unsafe_each` to clear the suspended flags; resuming there — by
   `pthread_mach_thread_np` for each thread it stopped — removes the bound from
   the path that hangs, with no allocation in the stop.
2. **Capture must cover every thread.** That needs a table sized to the thread
   count, and the table is read inside the stop, so it cannot be grown there:
   `malloc` under a stopped world is how the 2026-08-10 hang happened. Growing
   it at thread registration, or at collection entry before the first suspend,
   is the shape — and it wants its own gate, with a counter for "threads
   suspended without a slot" asserted at zero, which is the instrument this
   defect has been missing.

Half 1 is a contained change to a hang. Half 2 touches the root scan on a
platform whose STW is already the most fragile path in the tree. They should
not land together.
