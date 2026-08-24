# The collector waits for the Monitor; the Monitor waits for the collector

2026-08-24, aarch64 CI. **Fixed.** Cause proven, fix proven both ways.

## The cycle

`stop_world_quiescing_roots` took `@roots_lock`, then called `stop_world`,
whose first act was `MonitorGate.close`. That close spins until the Monitor's
current call ends — the comment there called the wait "bounded by that one
call", and nothing bounds the call.

One of those calls is `transfer_schedulers_blocked_on_syscall`. It reaches
`ExecutionContext.thread_pool.checkout`, and with no parked thread to hand out
that is `Thread.new` — `pthread_create`, which gcry wraps to root the new
`Thread` object: `ThreadBirthRoot.arm` -> `heap.add_root` -> **`@roots_lock`**.

    collector   holds @roots_lock, spins on the Monitor's busy bit
    Monitor     inside its call, blocked on @roots_lock

The Monitor is the one thread the suspend signals deliberately never touch, so
nothing breaks it.

## How it was found

Four sightings were misread first. The watchdog reported "waiting for thread
0x0" (a cleared breadcrumb read as a thread), then "every thread acknowledged;
the stall is after the wait loop" (**the previous stop's** breadcrumb, because
`@@suspend_*` were written only by `note_suspend` and survived between stops).
Fixing each in turn moved the answer: after the wait loop -> before it -> and
finally, with per-step markers, `entered, monitor gate not yet closed`.

That step name was written into this file as a prediction *before* the sighting
that produced it.

## The fix

Close the gate **before** taking `@roots_lock`. The Monitor can then finish the
call it is in — including the `pthread_create` that needs the lock — and clear
`busy`. The close inside `stop_world` stays, because `GC.stop_world` enters
there directly and would otherwise stop the world with the Monitor running.

## The proof

`make monitor-gate-deadlock`. A harness thread cannot stand in for the Monitor:
`@@busy` is one shared bit, so the real SYSMON's next back-off clears whatever
hold a fake takes — measured as `stw_waits=1, monitor_blocks=12` and no
deadlock in either arm. `GCRY_MONITOR_GATE_TEST_SPAWN=1` makes the real Monitor
do the spawn inside its handshake instead.

    gate closed before @roots_lock   finished, stw_waits=5
    GCRY_MONITOR_GATE_LATE_CLOSE=1   HUNG on try 3

`stw_waits=5` is what makes the green arm mean something: the collector really
did wait on the Monitor's busy bit five times and still got through.

The control arm gets tries rather than a fixed budget — the cycle is a race and
one attempt comes up empty about half the time.

## Not a regression

`make large-cache-race`'s locked arm faulted 1 of 5 on the first run with the
fix, which read as a regression. Paired at 60 runs each, splitting segfaults
from checksum failures:

    with the fix   segv 3, corrupt 0 of 60
    HEAD           segv 2, corrupt 0 of 60

Indistinguishable. The 5-of-30 reading that first raised the alarm was an
outlier; that arm is flaky at about 4 % on both sides, from a separate open
defect — `update_heap_bounds_after_unmap` walking `@chunks` onto a released
chunk, frame captured, not yet fixed.
