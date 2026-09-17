# An explicit `GC.collect` is usually a no-op under thread load, and says nothing

Linux x86_64, 20 hardware threads, `-Dgc_none --release`, N threads allocating
48-byte strings in a tight loop.

## What started this

The `stw_capture_no_slot` table in
`bench/log/linux/2026-09-17-darwin-64-thread-cliff/FINDINGS.md` had a row I could
not explain: at 71 threads the counter moved by **+0** across three explicit
`Gcry.collect` calls, when 5 threads (69 signalled − 64 slots) should go
uncovered every stop. I recorded it as unexplained. It is explained, and the
explanation is not about slots.

## `Heap#collect` has four silent early returns

    return if @destroyed
    return if @collecting
    return if monitor_thread?
    return if thread_not_ready_for_collect?

`@collecting` is the one that fires. It is set for the whole cycle, so an
explicit collect **returns immediately and silently whenever any thread is
already collecting**. Measured — `Thread.current.@name` is `DEFAULT-0` and
`@current_fiber` is non-nil on the calling thread, so the other two guards are
ruled out rather than assumed.

## How often the call does nothing

Asking continuously for one wall second and counting which of *our* calls
produced a pause:

| threads | explicit calls in 1 s | of those, landed a collection | total pauses in the window |
|---|---|---|---|
| 8  | 1 969   | **226** | 226 |
| 32 | 571 342 | **58**  | 59  |
| 70 | 85 682  | **6**   | 6   |

At 70 threads a given `GC.collect` has about a **1 in 14 000** chance of doing
anything, because a cycle takes ~145 ms (p50) and the flag is up for all of it.
Note the last column: in the 32- and 70-thread rows essentially every collection
in the window was one of *ours*. The collector is not collecting on its own
there — it is busy finishing the cycle a previous explicit call started.

So the API is not broken, it is **silent**: a caller who needs a collection to
have happened cannot learn from the return value whether one did. `GC.collect`
is not a barrier.

## Two claims of mine this retracts

1. **"2 000 001 explicit calls produced no pause at 71 threads."** Wrong, and
   the mistake is instructive: a call that returns in ~10 ns can be made two
   million times inside **5 ms**, so that loop sampled five milliseconds of a
   145 ms cycle and proved nothing. The measurement above is time-bounded for
   that reason.
2. **"Allocation throughput collapses 32× from 8 to 70 threads, and pauses grow
   54×, so the collector degrades superlinearly."** Refuted by its own control.
   With the collector off (`GCRY_DISABLE_AUTO=1`) the same threads collapse the
   same way:

   | threads | auto=on MB/s | auto=off MB/s |
   |---|---|---|
   | 8  | 2003.5 | 2470.1 |
   | 32 | 499.2  | 223.9  |
   | 70 | 62.1   | 74.6   |

   70 spinning allocators on 20 hardware threads is 3.5× oversubscribed, and at
   32 threads the run *without* the collector is the slower of the two. Nothing
   here separates the collector from the scheduler, so no collector claim is
   available from this host. The pause growth (2.71 ms at 8 threads to 145.69 ms
   at 70) is a collector number with no control, and it is confounded by the
   same oversubscription: every stop has to get 70 threads scheduled to
   acknowledge.

## The methodological half

A harness that calls `collect` and then reads a counter is measuring a **window**,
not a call — peers collect inside it, and the caller's own request may not have
run at all. That is what the `stw_capture_no_slot` rows were, and the "+70 per
collect" figure in that file is per *window*. The conclusion there is unaffected
(the counter is exactly zero below the bound and non-zero above it, which needs
only that stops happen), but the attribution was wrong and is corrected in
place.

`bench/darwin_stw_resume.cr` is not affected: its workers allocate 16 bytes
every 5 ms, so `@collecting` is almost never up when it asks, and its counters
showed exactly two stops for two calls (142 = 2 × 71).

## Fixed, and what it cost

`Heap#collect` now returns early only when the **calling thread** is inside its
own cycle — `@collecting` *and* `@collector_pthread == pthread_self()`, read
together because `@collecting` alone does not say whose cycle it is and the
identity alone can be stale. A peer's cycle is waited for in `run_collection`,
which already acquires `@post_stw_mutex` at entry; the early return was the only
thing that had prevented that wait. So this is a narrowed guard, not a new wait
loop.

Blast radius is exactly the explicit path: the allocation path is
`maybe_collect`, which has its own `return if @collecting` and is untouched, and
the public `collect` has two callers — `Gcry.collect` and `GC.collect`
(`gc_override.cr`). `collect_a_little` keeps its own early return, because an
incremental *slice* that blocked would stop being a slice.

Gated by `make explicit-collect-barrier`, three bounded arms:

| arm | threads | calls | landed |
|---|---|---|---|
| busy  | 32 | 20 | **20/20** |
| skip (`GCRY_COLLECT_SKIP_WHEN_BUSY=1`) | 32 | 20 | **0/20** |
| quiet |  0 | 20 | **20/20** |

The `skip` arm is the pre-fix guard and it loses the guarantee completely at this
thread count, which is what makes the `busy` arm's 20/20 mean something. Twenty
calls rather than one on purpose: the pre-fix behaviour is probabilistic (~1 in
9 850 at 32 threads), so a single call would have passed by luck often enough to
look green.

**The cost is real and shows up in an existing harness.**
`make thread-startup-cost`'s collect arm asks for a collection every 2 ms, and
those calls now actually collect:

| arm | n | join_ms before | join_ms after | collections after |
|---|---|---|---|---|
| collect | 8   | 31.6  | 179.6  | 13 |
| collect | 32  | 65.1  | 367.8  | 12 |
| collect | 64  | 41.3  | 267.4  | 12 |
| collect | 100 | 85.7  | **3638.1** | 11 |

40× at n=100, and it is the arm doing what it always said it did — "a dedicated
thread calling `GC.collect` every 2 ms through the storm" — rather than being
skipped. Well inside the harness's 120 s per-cell budget. The pre-fix numbers in
`bench/log/linux/2026-09-17-thread-startup-cost/FINDINGS.md` and in the
Darwin cliff record are not comparable to anything measured after this change,
and both are annotated.

## Not designed here

Making `collect` a barrier — wait for an in-flight cycle rather than returning
— is a change to a public API's behaviour under load, and it needs the owner
check to avoid deadlocking a collect called from a finalizer (`@stw_owner_pthread`
already records who is collecting). It has a red arm by construction: N
hard-allocating threads and one explicit call, asserting a pause followed. That
is a separate change with its own gate.


## The first gate's red arm came out green on CI

`make explicit-collect-barrier` failed on the Linux job of runs 35226651277 and
35226882013 — not on the arm under test, but on its **control**:

    arm skip: 32 allocating threads, 20 explicit collects, pre-fix skip-when-busy guard
    landed=20/20 missed=0 pause_p50=343.28ms
      - all 20 calls completed a collection with the pre-fix guard in place

The pre-fix guard refuses a call only while *another* thread is collecting, and
the first version of this harness arranged that by having 32 threads allocate
hard. On a 20-core host that keeps the collector busy continuously, so the arm
missed 20/20. On a 4-vCPU runner the same 32 threads allocate slowly enough that
collections are *rare* — `pause_p50` was 343 ms there against 25 ms here, and
the gaps between them are what the calls landed in. So the arm's red direction
was a function of the host's core count, which is not a gate.

Restricting this host with `taskset -c 0-3` did **not** reproduce it: four fast
cores still keep the collector busy. The reproduction is the CI log, and the
lesson is the same either way — the window the control needs was being *hoped*
for rather than arranged.

**Fixed structurally.** A dedicated thread now does nothing but call
`GC.collect`, so a cycle is in flight essentially always regardless of core
count, and every measurement is taken after `heap.collecting?` has been observed
true (a new predicate, exposed for exactly this). The harness reports
`asked_without_a_cycle_in_flight`, so an arm that measured outside the window
says so instead of quietly reading zero.

Verified on 20, 4, 2 and **1** CPU — the last with the collector thread and the
prober sharing a single core:

| CPUs | busy | skip | quiet |
|---|---|---|---|
| 20 | 20/20 landed | 0/20 landed | 20/20 landed |
| 4  | 20/20 | 0/20 | 20/20 |
| 2  | 20/20 | 0/20 | 20/20 |
| 1  | 20/20 | 0/20 | 20/20 |

`asked_without_a_cycle_in_flight` was 0 in all twelve arms.


## The barrier can be starved, and that is a property of it

Second CI failure of the same gate (run 35229134467), and this time the arm
under test rather than the control:

    arm busy: 4 allocating threads + one collector thread, 20 explicit collects
    bench: child exceeded 90s and was killed
    arm skip: ... landed=0/20 missed=20   <- the control is now correctly red

The window-holding thread called `GC.collect` in a loop with no sleep, so it
re-entered `run_collection` the instant it left. `@post_stw_mutex` is a plain
`pthread_mutex_t` with no fairness guarantee, and on the 4-vCPU runner the
looping thread re-acquired it before the waiting prober was ever scheduled — for
ninety seconds. Two milliseconds of sleep between cycles fixes the harness (the
window is still open ~96% of a ~45 ms cycle) and all three arms then pass at 20,
4, 2 and 1 CPU in about 7 s.

**Not reproduced on this host**, at any core count, which is why the sleep is
justified by the mechanism and the CI log rather than by a local red-to-green.

The underlying property is worth stating plainly, because it is new: an explicit
`GC.collect` now *waits*, so against a thread that collects in a tight loop it
can wait for a long time. Pre-fix it returned instantly having done nothing,
which is not better — it is the same starvation with the failure hidden.

**Deliberately not softened.** The obvious mitigation is to return as soon as a
*peer's* cycle completes, which would bound the wait to roughly one cycle. That
is a weaker guarantee and the wrong one: a peer's cycle may have snapshotted the
heap *before* this call, so objects that became unreachable at call time can be
marked live by it. "Collect now" should mean a cycle that began after the
request, so the implementation runs its own and the wait stays honest.
