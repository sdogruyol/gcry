# The EC Monitor keeps running — and frees memory — while the world is stopped

**Date:** 2026-08-11 · host: R9-9950X, WSL2, Crystal 1.21.0 (`57cf7da50`),
`-Dgc_none`, default execution context · tip @ `5393571`

`Heap#stop_world` deliberately does not signal-suspend the EC Monitor. The
reason is recorded in `collect_stw.cr`:

> Do not SIGPWR-suspend the Monitor (`SYSMON`): resume races leave it in
> `sigsuspend` forever. Instead mark `@world_stopped` and make allocate/lock_read
> spin until start_world (cooperative STW).

**The cooperative half does not happen.** Measured, not argued.

## What was measured

`GCRY_STW_TEST_STALL_MS` holds the world stopped inside the thread-stacks phase,
which makes a µs-scale window observable from outside the process.

**1. The Monitor runs at full cadence through a 4 s stop.** Sampling
`/proc/<tid>/status:voluntary_ctxt_switches` every 250 ms while the mutator sat
frozen in `GC.collect` (its own counter pinned at 3):

```
SYSMON wakeups:  95 → 120 → 144 → 169 → 194 → 219 → 244 → 269 → 294
                → 318 → 343 → 368 → 393 → 418 → 443
mutator wakeups:  3 (unchanged throughout)
```

~25 wakeups per 250 ms — about 100/s, for the whole stop. Its loop is
`Thread.sleep` → `transfer_schedulers_blocked_on_syscall` → `increase_parallelism`
→ `collect_stacks`, and none of that reaches the `allocate` / `lock_read`
checkpoints the cooperative design depends on.

**2. It frees fiber stacks inside the window.** Built `-Dtracing`, run with
`CRYSTAL_TRACE=sched`, an 8 s stall and the watchdog armed at 1 s:

```
MARK collect-begin
gcry: STOP-THE-WORLD STALLED 1041 ms in phase=thread-stacks
sched.collect_stacks 497358987154350 thread=…:SYSMON fiber=…:main duration=250299
MARK collect-end
```

That `collect_stacks` is `Monitor#collect_stacks` → `StackPool#collect` →
`Crystal::System::Fiber.free_stack`, which the stdlib documents as *"Removes and
frees at most count stacks from the top of the pool, returning memory to the
operating system"* — i.e. **munmap, on a thread the collector believes is
stopped, while the collector is in its thread-stacks phase.** It took 250 µs.

## What this does and does not establish

**Established:** every safety argument in this repo that begins "the world is
stopped" silently excludes one thread, and that thread does memory management.
The Monitor also mutates scheduler ownership
(`transfer_schedulers_blocked_on_syscall`) and can raise parallelism — which
creates threads — in the same window.

**Not established:** that this corrupts anything. Pooled stacks belong to fibers
already delisted from `Fiber.unsafe_each` (`Fiber#run` calls `Fiber.inactive`
before the stack is released), so the collector should not be scanning a stack
the pool is freeing. No corruption has been traced to this.

It is, however, a candidate mechanism for the nightly soak SEGV
(`bench/log/linux/2026-08-10-*`, crash inside
`Parallel::Scheduler#quick_dequeue?` at a half-overwritten pointer
`0x7f1700000149`), which is unexplained and did not reproduce in 4 h locally.
Rate fits: `COLLECT_STACKS_EVERY` is 5 s and a real STW is µs, so the overlap is
rare per collection and near-certain across a 24 h soak.

## Shape notes gathered along the way

- The default execution context on Crystal 1.21 is `Parallel`, but
  `init_default_context` calls `Parallel.default(1)` — **maximum parallelism 1**.
  `default_workers_count` (which reads `CRYSTAL_WORKERS` / CPU count, 32 here) is
  a helper for callers who resize; it is *not* used for the default context.
- Measured: a plain `-Dgc_none` build stays at **2 threads** (worker + SYSMON)
  both idle and with 200 busy fibers, and the running 12 h soaks are at 2 threads.
  So `multi_mutator_threads?` (> 2) is false in the default shape, and the docs'
  "EC1" framing holds for worker count even though the scheduler class is
  `Parallel` — which is why the nightly crash trace names `Parallel::Scheduler`
  without implying multiple workers.

## Fixed — `Gcry::MonitorGate`, a handshake

Option 1 below, in the full form: an entry check alone would only stop the
Monitor *starting* work during a stop, and the observed `collect_stacks` took
250 µs, so work already in flight had to be waited out too.

```
Monitor:     busy = 1 ; if stopped { busy = 0 ; wait until !stopped ; retry }
stop_world:  stopped = 1 ; wait until busy == 0
```

Both sides store then load, which is the one shape a relaxed ordering would let
through, so every access is sequentially consistent. The Monitor clears `busy`
*before* waiting, so it can never hold the collector while waiting on it.

**No compiler fork.** The three things `Monitor#run_loop` calls every ~10 ms
(`transfer_schedulers_blocked_on_syscall`, `increase_parallelism`,
`collect_stacks`) are wrapped from the shard by reopening the class and calling
`previous_def` — verified to take effect before relying on it (604 hook firings
in 6.5 s on a plain `-Dgc_none` build). `run_loop` itself is not wrappable: it
never returns, so a wrapper around it could check exactly once.

**Verified both ways** (`make stw-monitor-gate`, `bench/stw_monitor_gate.cr`),
over a 20 s stop so the control gets several chances at the 5 s collect interval:

| run | `collect_stacks` inside the stop | Monitor held off |
|-----|---------------------------------:|-----------------:|
| gate on | **0** | 1× |
| gate off (`GCRY_MONITOR_GATE=0`, control) | 4 | 0 |

The "held off" column is load-bearing: a clean window with the Monitor never
blocked would mean nothing happened to be scheduled, not that anything closed.
Removing `MonitorGate.close` from `stop_world` turns both assertions red (4
inside, 0 held off).

**This gate was wrong twice, and CI caught both.** Worth recording, because both
mistakes were over-specification rather than a real defect in the collector.

The first version asserted *no* trace line between the marks. But `Crystal.trace`
emits its line when the work *finishes* — it reports `duration=` — so a
`collect_stacks` already in flight when the stop began lands after the begin mark
even though `stop_world` correctly waited it out. Rare on 32 threads, likely on a
2-vCPU runner: it passed locally and failed on master.

The second version counted lines but demanded that a single line inside be
accounted for by `stw_waits >= 1`. Also wrong. The child prints its mark before
`GC.collect`, and the path from there to a stopped world runs through collect
entry, the write lock and the roots/finalizer locks — not instant on a loaded
runner. A `collect_stacks` finishing in *that* window was never inside a stopped
world and no wait is recorded for it, so the assertion demanded a mechanism the
run need not exhibit.

What survives is the count, which is what the gate is actually for: with the
handshake removed the run measures **4** lines inside a 20 s stop (control and
break-gate agree); with it, **0–1**. `stw_waits` is reported rather than
asserted — when it is non-zero it is the pause the handshake added.

**Cost, measured rather than argued.** Over 3000 collections with 200 busy
fibers: `stw_waits=0`, `stw_wait_max_ns=0`, `monitor_blocks=397`. The collector
never once had to wait for in-flight Monitor work, while the handshake engaged
397 times. Typical added pause is zero; the worst case is bounded by one Monitor
call (250 µs for the `collect_stacks` measured above), and it is countable rather
than guessed — `monitor_gate_stw_waits` / `_stw_wait_max_ns` on `/gc-stats`.

**Still open:** whether any of this was the nightly SEGV. The mechanism is closed
either way; the crash is not yet explained.

## The options as they stood

1. **Make the Monitor cooperate for real** *(taken)* — have its loop hit gcry's existing
   `wait_if_world_stopped_other_thread` once per iteration. Smallest change, and
   it is the thing the comment already claims happens. Blocking the Monitor for a
   µs-scale stop is what a collector wants; note this is *cooperative spinning*,
   not the signal-suspension that deadlocked it before.
2. **Suspend it like any other thread** — the recorded reason not to is a resume
   race, which is worth re-testing now that the resume path re-signals.
3. **Leave it running and make every STW-time invariant explicit about it** —
   cheapest, and the worst of the three: it keeps a documented assumption false.

Whatever lands needs a gate. The probe above is one: with `-Dtracing`, assert no
`sched.collect_stacks` line falls between the stall's begin and end marks. It is
red today, by construction.
