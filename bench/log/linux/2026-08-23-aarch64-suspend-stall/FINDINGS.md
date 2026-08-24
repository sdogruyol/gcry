# The aarch64 suspend stall, sighted — and the report that misread it

CI run `32638359761`, `test (aarch64 native)`, 2026-08-23. The job ran
`make ec-queue-audit` in its control mode and hung; the step was killed at the
timeout (exit 124). The watchdog printed:

    gcry: STOP-THE-WORLD STALLED 10017 ms in phase=suspend
    gcry: waiting for thread 0x0 to acknowledge its suspend signal

Re-running the same job on the same commit passed in 4m3s. It is intermittent,
and it is the hang that has been open since 2026-08-22 (`32575506486`) — not a
regression from the chunk-walk work pushed in the same commit. That was checked
before anything else: `flush_pending_large_release` is the only new
`@alloc_lock` acquisition near a stop, and every one of its call sites is after
`start_world`. No in-STW path takes `@alloc_lock` at all.

## What the report got wrong

`0x0` is not a thread. `stop_world` clears the watchdog's breadcrumb when the
wait loop finishes — `note_suspend(expected, acked, 0)` — so a zero there means
*every thread acknowledged and the loop is done*. The report read it as the
thread it was waiting for and said so, which sent a reader into thread handles
and `pthread_kill` for a stall that was not in the wait loop at all.

The positive control could not have caught it: `GCRY_STW_TEST_SUSPEND_STALL_MS`
stalls *before* the loop and plants a fake non-zero id (`0xdead…1`), so the
zero branch had never once been exercised.

Fixed both halves. `GCRY_STW_TEST_POSTSUSPEND_STALL_MS` holds the phase open
after the loop, reproducing the CI shape exactly, and `make stw-watchdog` now
asserts the report says

    gcry: every thread acknowledged (N of N); the stall is after the wait loop,
    not in it

Broken on purpose, both assertions fire.

## 2026-08-24: the corrected report earned its keep

Run `32698202277`, aarch64 native, `make ec-queue-audit`, exit 124 again — and
this time the watchdog said something usable:

    gcry: STOP-THE-WORLD STALLED 10018 ms in phase=suspend
    gcry: every thread acknowledged (2 of 2); the stall is after the wait loop,
          not in it

Both threads acknowledged their suspend. The collector is wedged *after* the
wait, which is exactly what the old "waiting for thread 0x0" wording hid.

That still was not narrow enough, because `PHASE_SUSPEND` covered three
regions: the tail of `stop_world` after the last ack, the return through
`stop_world_quiescing_roots`, and that wrapper releasing `@roots_lock` and the
finalizer lock with the world already stopped. Reading the code rules out the
first two — the tail is one assignment and the caller does one timestamp before
`PHASE_FLUSH` — but reading is not measuring, and this is the third structure
today whose comment outlived its condition.

So the span is split. `PHASE_STOPPED` (stopped-before-flush) is entered right
after the last ack; `PHASE_QUIESCE` (quiesce-release) before those unlocks. The
next sighting names one of the three instead of all of them.

`GCRY_STW_TEST_STOPPED_STALL_MS` is the control, and `make stw-watchdog`
asserts on it. Broken on purpose — the phase entry removed — the gate goes red
with "the span between the suspend wait and the flush is still reported as
`suspend`". A phase nobody can show firing is a phase nobody has seen.

## What is still open

Where the 10 seconds went. The breadcrumb now says only that it was *after* the
suspend loop and before the phase advanced past `suspend`. Nothing in that
window has been narrowed yet, and no sighting has been reproduced off CI —
the machine here is x86_64.

Worth noting for the next sighting: `stop_world` takes `@roots_lock` and a
mutator adding a thread-birth root takes the same lock (`collect.cr:543`), and
`ec-queue-audit` exercises exactly that — `ExecutionContext::Parallel` spawning
threads. That is a hypothesis, not a finding; it has not been tested.
