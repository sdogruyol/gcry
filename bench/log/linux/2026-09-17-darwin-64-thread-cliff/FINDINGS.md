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

## Three corrections to the first reading

Made while designing the fix, and they matter:

- **Slots are recycled per STW.** `clear_thread_sps` zeroes `@@stw_claimed` and
  every `@@stw_greg_ok`. An earlier reading of mine had them accumulating for
  the process's life, which would have meant 64 *distinct* threads were enough
  to lose capture permanently. Wrong, and withdrawn.
- **The 64 is not Darwin's.** `@@stw_claimed` is an `Atomic(UInt64)` — a 64-bit
  bitmask — and `linux_stw.cr` and `windows_stw.cr` carry the identical scheme.
  Capture past 64 concurrent threads is lost on **every** platform. Defect 2
  above is cross-platform; only Defect 1 is Darwin's.
- **Linux already names the condition.** `SUSPEND_NO_SLOT = -2`, "Admitted, but
  with no slot to answer through: the table is full", with a deliberate choice
  to cost that thread its SP clamp rather than the stop. So the ceiling is
  known and handled there — and, as far as I can find, counted nowhere. Darwin
  has no such branch at all.

## One bound, three behaviours

Found while wiring the counter, and it corrects a claim I had just committed
(the comment in `windows_stw.cr` said all three platforms behaved alike):

| platform | past `MAX_STW_SP_SLOTS` live threads |
|---|---|
| Windows | **refuses the stop.** `try_stop_world_threads` checks the count *before* suspending, breaks, and `raise_thread_suspension_error` says "or exceeded 64 threads". No silent loss, no hang — it declines to collect. |
| Linux | **admits the stop, loses the capture.** `SUSPEND_NO_SLOT`, by an explicit decision to cost the thread its SP clamp rather than the stop. Silent root loss; measured below. |
| Darwin | **hangs.** Suspends unconditionally, records the port only while a slot is free, resumes only what it recorded. |

So the loudest platform is the one nobody worried about, and Darwin's defect is
not that it shares a bound — it is that it is the only one whose *resume* is
sized by the table. Windows also shows the answer Half 2 has to improve on:
refusing to collect past 64 threads is correct and unacceptable.

## Measured on Linux, 2026-09-17: the capture ceiling is not hypothetical

The design's step 1 — `stw_capture_no_slot`, a counter on every platform for a
slot claim that found the table full — is in, reporting only. Linux x86_64,
this host, `-Dgc_none --release`, N spinning allocator threads plus the main
one, three explicit `Gcry.collect` calls each:

| threads on `Thread` list | at start | per collect | total |
|---|---|---|---|
| 9   | 0  | +0 +0 +0    | 0   |
| 33  | 0  | +0 +0 +0    | 0   |
| 71  | 10 | +0 +0 +0    | 10  |
| 101 | 0  | +70 +70 +70 | 210 |

Below the bound it is **exactly** zero, every collect. Above it, non-zero. That
is a counter that discriminates rather than one that survives, and it is the
first measurement of the capture ceiling on Linux — the Darwin probe in this
same directory only ever showed the hang, which is the other defect.

`+70` on 101 threads is about two per uncovered thread (101 − 1 current − 64 =
36), which fits the counter's documented multiplicity: on Linux the collector
reserves a slot through `reserve_suspend_slot` *and* the handler claims one
through `record_thread_sp`, so an uncovered thread fails twice.

**The anomaly in the 71-thread row is explained, and it was not about slots.**
At 71 threads the counter read 10 from startup and then **+0** for all three
explicit collects. `Heap#collect` returns silently when `@collecting` is already
set, and with 70 hard-allocating threads a cycle takes ~145 ms — so about 1 call
in 14 000 does anything. Those three calls did nothing at all; the `stw_records`
shortfall (138, not ~213) is the same fact. Measured in
`bench/log/linux/2026-09-17-explicit-collect-noop/FINDINGS.md`.

Which means the column header **"per collect" above is wrong: it is per
window**, and peer collections land inside it. The conclusion is unaffected —
the counter is exactly zero below the bound and non-zero above, which needs only
that stops happen — but the attribution was mine and it was loose.

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

**Both are designed in `DESIGN.md` beside this file**, including the sequencing,
the counter that has to come first, why the `@suspended` flag is the wrong
resume record, the one hazard in the list-walk resume, and the O(n²) slot search
that becomes the next cliff once the ceiling is lifted.


## Verified on Darwin, 2026-09-17: run 35223283452

Half 1 landed and the macOS job ran it. `make darwin-stw-resume`, three arms,
Apple Silicon runner:

| arm | threads | resume | suspended | resumed | stalled |
|---|---|---|---|---|---|
| hold    | 70 | shipped thread list | 142 | **142** | 0/70 |
| bounded | 70 | pre-fix 64-entry table | 142 | **128** | **7/70** |
| control |  8 | pre-fix 64-entry table | 18 | **18** | 0/8 |

The arithmetic is the whole argument: 142 = 2 collections × 71 threads (the 70
workers plus the one the harness holds), 128 = 2 × 64, and the difference of 14
is 2 × 7 — exactly the 71 − 64 threads the table cannot hold. The bounded arm
reported `suspended=142 but resumed=128: 14 thread(s) were suspended and never
resumed` and 7 workers that made no progress in 250 ms after the world
restarted. The control arm says the knob alone is harmless, so the hold arm's
equality is attributable to the bound.

And the probe that started this, `make thread-startup-cost`, in the same job.
The two cells that had been **TIMEOUT at 120 s** now complete:

| arm | n | before | after |
|---|---|---|---|
| collect | 8   | 7.6 ms      | 943.3 us/thread, 9 collections |
| collect | 32  | 32.3 ms     | 175.8 us/thread, 9 collections |
| collect | 64  | **TIMEOUT** | **236.2 us/thread, 7 collections** |
| collect | 100 | **TIMEOUT** | **60.5 us/thread, 4 collections** |

us/thread on the collect arm now *falls* from 943.3 at n=8 to 60.5 at n=100
(×0.06), the same shape Linux always had. The O(n²) reading is refuted a second
time, now with the data at n=64 and n=100 that could not be collected at all
while the bound was there.

What this does **not** establish: that Half 2 is unnecessary. `stw_capture_no_slot`
is still non-zero past 64 threads on Linux and Darwin — the capture ceiling is
untouched, and this gate asserts only that the world comes back.
