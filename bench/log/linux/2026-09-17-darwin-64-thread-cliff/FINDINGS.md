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


## Baseline note: the collect arm's numbers predate the explicit-collect barrier

Every `collect`-arm figure above was measured while `Heap#collect` returned
immediately whenever any thread was already collecting, so most of the harness's
2 ms requests did nothing. That guard was narrowed on 2026-09-17
(`bench/log/linux/2026-09-17-explicit-collect-noop/FINDINGS.md`) and those calls
now complete a collection each. The same Linux cells moved from 31.6 / 65.1 /
41.3 / 85.7 ms of join time to 179.6 / 367.8 / 267.4 / 3638.1 ms, with 11-13
collections per cell instead of a handful. Nothing measured after that change is
comparable to the numbers above.


## Re-measured after the explicit-collect barrier: the counter is arithmetic

The table further up measures windows, because most of its explicit collects
did nothing (`bench/log/linux/2026-09-17-explicit-collect-noop/FINDINGS.md`).
With that guard narrowed, every call lands and the counter becomes exact. Same
host, gentle workers (16 bytes every 5 ms, so nothing else is collecting),
five explicit collects each:

| threads on Crystal's list | need a slot | `stw_capture_no_slot` per collect |
|---|---|---|
| 9   | 7  | +0 +0 +0 +0 +0 |
| 33  | 31 | +0 +0 +0 +0 +0 |
| 65  | 63 | +0 +0 +0 +0 +0 |
| 71  | 69 | +10 +10 +10 +10 +9 |
| 101 | 99 | +68 +70 +68 +70 +69 |

"Need a slot" is the list minus the collector itself and minus `SYSMON`, the two
threads `stop_world` skips. The relationship is

    no_slot per collect  =  2 x max(0, needing_a_slot - MAX_STW_SP_SLOTS)

— 69 − 64 = 5 → 10, and 99 − 64 = 35 → 70 — where the 2 is the documented
multiplicity on Linux: `reserve_suspend_slot` fails once before the signal and
`record_thread_sp` fails again inside the handler. The odd rows (+9, +68) are a
thread that had not finished starting when that stop began.

**The 65-thread row is the one that matters for Half 2's gate**: exactly at the
bound, nothing is lost, so a gate can assert zero there and non-zero one thread
later. That is a discriminating pair, and it was not available before the
barrier landed — with unlanded collects the same arms read +0 either way, which
is how the earlier table came to say "+0" for a case that loses five threads'
registers every stop.


## Half 2, and the claim it corrected first

Before touching the tables I checked the two things the design had assumed
rather than measured. Both answers changed the work.

**1. A missing SP clamp is conservative, not a loss.** `scan_pthread_stack`
takes `sp : Void*?`, and with `nil` the `if sp` branch is skipped, so `low`
stays at the snapshotted bounds and the **whole** stack is scanned. A thread
with no slot is therefore scanned more, not less.

**2. On Linux the registers are on the thread's own stack.** The suspend handler
is installed with `action.sa_flags = LibC::SA_SIGINFO` and **no `SA_ONSTACK`**,
so the `ucontext_t` the handler reads its registers out of sits on the
interrupted thread's stack, below the interrupted SP. An unclamped full-stack
walk covers it. So Linux's no-slot case loses **precision, not roots**.

That retracts a claim I had made in the design, in the ROADMAP and in v0.26.1's
CHANGELOG — "past it Linux and Darwin suspend the thread and scan it with no SP
clamp and no registers, so a reference live only in the 65th thread's registers
is not a root". True on Darwin, where `thread_get_state` is the only copy. Not
true on Linux.

**What Half 2 therefore is:**

| platform | before | after |
|---|---|---|
| Darwin  | past 64 threads: no SP clamp, **no registers** — a real missed root | table grows with the thread count |
| Windows | past 64 threads: **the stop is refused**, so a 65-thread process cannot collect at all | table grows; a thread it cannot hold is suspended and scanned unclamped, counted, not refused |
| Linux   | past 64 threads: unclamped full-stack scan, registers still covered via the on-stack ucontext | **unchanged, deliberately** |

Linux is left alone because its loss is precision and its table is the one
shared with a signal handler that claims from every thread at once — the part of
the original design that needed `Atomic::Ops` on malloc'd memory and a
never-freed table to survive a stale handler. Neither is needed on the two
platforms that changed: there `slot_for` runs only on the collector, one thread
at a time, so the 64-bit claim mask — which *was* the bound, since a `UInt64`
cannot address a 65th slot — became one plain byte per slot.

**How the tables grow:** `LibC.malloc`, doubling from 64, at collection entry
before the first suspend, sized from `Thread.unsafe_each` plus eight slots of
slack for threads born during the stop. No copy: every slot is per-STW. If the
allocator refuses, the old table stays and `stw_capture_no_slot` counts what
does not fit — the collection is not failed, because refusing to collect is the
behaviour this replaces. Static arrays could not do this: the greg row is
GREG_WORDS wide per slot, and a table for a thousand threads is a quarter to
three quarters of a megabyte of BSS, which on these platforms is a
**conservative static root range** — the same property that made a 256 KiB
report buffer shift chunk residency on the aarch64 runner.

**And the O(n²) the design flagged:** `slot_for` is a linear scan and was called
twice per thread per stop. Both stop loops now hand the index down —
`capture_thread_state(port, id, slot)` on Darwin, `record_thread_context_at` on
Windows — so it is once.

**Gated by `make stw-capture-coverage`**, three bounded arms: 80 threads with
`stw_capture_no_slot == 0`, the same pinned by `GCRY_STW_FIXED_SLOTS=1` where it
must be non-zero, and 8 threads under that knob where it must be zero. The
harness also reports `stw_slot_capacity` and asserts it grew, so a zero cannot
be read as coverage when the table was never asked for more, and requires
`thread_greg_words_total` to have moved so an arm that captured nothing fails
its own precondition rather than passing.

**Not verified on either platform by me.** No Darwin or Windows host here. What
is verified locally: all four cross-targets type-check, the Linux suites and
every STW gate still pass (`greg-roots`, `scheduler-roots`, `dead-stack-root`,
`tls-roots`, `stw-epoch`, 277 + 32 examples), and the harness skips on Linux
with its reason. The Darwin and Windows CI jobs are the first execution.


## Half 2, measured on the runners (2026-09-18, run 35381875960)

`make stw-capture-coverage`, in the job for each platform:

| platform | threads on list | slot capacity | `no_slot` | register words offered |
|---|---|---|---|---|
| Darwin | 82 | 128 | 0 | 2843 |
| Darwin, `GCRY_STW_FIXED_SLOTS=1` | 82 | 64 | **34** | 2297 |
| Darwin, pinned, 10 threads | 10 | 64 | 0 | 318 |
| Windows | 83 | 128 | 0 | 1663 |
| Windows, `GCRY_STW_FIXED_SLOTS=1` | 83 | 64 | **36** | 1288 |
| Windows, pinned, 11 threads | 11 | 64 | 0 | 208 |

Two things worth reading off that table. The pinned arm loses 34 and 36 threads
respectively — those are threads suspended with no SP clamp and **no registers**,
and 546 / 375 fewer register words reach the mark as a result. And the third row
on each platform is what makes the first row mean anything: the same knob, inside
the table's capacity, turns nobody away.

`make stw-slots-grow-race` in the Linux job, which covers the rule that the
growth never frees its predecessor:

    hold 1/3: ok child: grown=12 capacity=262144 reader_passes=89
    hold 2/3: ok child: grown=12 capacity=262144 reader_passes=97
    hold 3/3: ok child: grown=12 capacity=262144 reader_passes=93
    free 1/3: died   free 2/3: died   free 3/3: died

Windows' library suite, which had been wedging for the whole 20-minute job
budget: **278 examples, 0 failures, 7.06 s.**
