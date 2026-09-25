# The stw_mt stall is a Crystal Parallel-scheduler deadlock, not gcry

**Date:** 2026-09-25 · host: Linux 7.0.0-31-generic x86_64 (QEMU, 12 vCPU),
Crystal 1.21.0 · `ping.cr` beside this file

## The stall

`stw_mt_property_test` stalled twice in the loaded stress campaigns (seed 1032,
900 s; seed 20003, 300 s), about one run in a hundred, and never on a quiet host
(0 of 300). The overnight campaign captured the second with every thread's
backtrace (`gcry-stall-threads.txt`):

* both Parallel worker threads **running** (state `R`), spinning in
  `Fiber::ExecutionContext::Parallel::Scheduler#resume` →
  `Thread.delay` → `sched_yield` (`parallel/scheduler.cr:97`), each reached from
  a worker fiber suspending in `Channel#send` / `#receive`;
* the main thread idle in `epoll_wait`, its fiber waiting for a worker;
* no collection in progress, the STW watchdog silent, `gc-idle` asleep.

`resume` spins until the target fiber's context has been saved
(`until fiber.resumable?`), and the spin sits *before* the resuming thread's own
`swapcontext`, so the fiber that thread is running is still "running" too. If
each of two threads has dequeued the other's current fiber — both enqueued by a
channel wake-up while still on their way into `suspend` — each waits for the
other to save a context the other will only save after its own wait ends. The
scheduler's source names the risk:

    # OPTIMIZE: if the thread saving the fiber context has been preempted,
    # this will block the current thread from progressing... shall we
    # abort and reenqueue the fiber after MAX attempts?

## Not gcry: reproduced under Boehm, and without any GC

`ping.cr` is the harness's traffic with nothing else: two Parallel workers send
on an unbuffered channel and wait for an ack from the main fiber. Built with the
default GC (Boehm), under the same background load:

| build | runs | stalled | shape |
|---|---|---|---|
| Boehm, `GC.collect` every 8 round trips | 152 | **3** | identical (`boehm-stall-threads.txt`) |
| Boehm, no `GC.collect` at all | 74 | **3** | — |

So it is the scheduler alone.

## The mechanism, measured

`resume_giveup.cr` is `ping.cr` with `Scheduler#resume` redefined to record,
per worker thread, the fiber it is running and the fiber it is resuming, and a
watchdog thread — raw `nanosleep` and `write(2)`, since anything through the
event loop can be what is stuck — that prints both when progress stops for 3 s.
Without `FIX=1` it runs 1.21.0's logic unchanged. **Every stall was the
circular wait**: 4 of 4 in a first batch (a `previous_def` wrapper), 18 of 18
in the control arm below:

    STALL after 2287 round trips
      w-0: running worker-fiber-0, resuming worker-fiber-1 (target resumable at entry: false)
      w-1: running worker-fiber-1, resuming worker-fiber-0 (target resumable at entry: false)
      circular wait: true

## A fix that breaks the cycle, measured

The `OPTIMIZE` note's own idea: stop spinning after a bound, requeue the target,
and switch to this scheduler's main loop fiber instead. Switching saves the
current fiber's context, so the *other* thread's spin ends; the main loop finds
the requeued fiber once its context is saved. Never from the main loop fiber
itself — it has nowhere to go — and no cycle can pass through it, because its
thread runs no fiber while it spins. `FIX=1` toggles it in the same binary
(the bound counts spins itself: `Thread.delay`'s return value is a backoff that
wraps to 0 after 7, which the first version compared against 1000 and so never
gave up — that run measured two identical arms, 14 vs 19 stalls).

| arm, interleaved, 2 500 runs each | stalls | gave up |
|---|---:|---:|
| control | **18** (18 circular) | — |
| give up after 1 000 spins | **0** | 9 times, in 9 runs |

Each give-up is a deadlock broken rather than hung — 9 against the control's
18 is the right order for the same exposure.

**And as an upstream patch.** `resume-requeue.patch` is the same change
against Crystal **master**'s `scheduler.cr` (whose `resume` is identical to
1.21.0's). Applied to a copy of the 1.21.0 stdlib and used through
`CRYSTAL_PATH`, it leaves the reproducer itself untouched — `ping.cr` exactly
as above, no instrumentation, no redefinition — and the A/B is the cleanest
one here:

| `ping.cr` against, interleaved, 2 500 runs each | stalled (> 20 s) |
|---|---:|
| stock 1.21.0 stdlib | **72** |
| stdlib + `resume-requeue.patch` | **0** |

(The uninstrumented binary stalls more often, 2.9%, than the instrumented one,
0.7% — instrumentation perturbs the window, as it would.)

This is Crystal's scheduler to fix, not gcry's to patch around: a shard
redefining `Scheduler#resume` would change the runtime under every user of it. A collector's stop-the-world pauses can only
change how often threads are preempted inside the window, and gcry's rate
(~1%) is if anything *below* Boehm's here (2–4%).

## What changes in this repo

* The ROADMAP item for the stall is closed as upstream.
* `bench/run_bounded.sh` classifies a stall whose capture shows two or more
  threads in `parallel/scheduler.cr:97` and no collector frame as this known
  upstream deadlock (exit 3), so the samplers report it without counting it as
  a gcry failure.

## Draft upstream report (not filed)

> **Parallel execution context: two schedulers can deadlock resuming each
> other's current fiber**
>
> Crystal 1.21.0, Linux x86_64. Two fibers in a `Parallel` context doing
> channel ping-pong with a fiber in the default context occasionally hang
> forever: both scheduler threads spin in `Scheduler#resume`
> (`parallel/scheduler.cr:97`, `until fiber.resumable?`) and the default
> context idles in `epoll_wait`. Each thread appears to have dequeued the
> fiber the other is still running — both woken by a channel operation while
> on their way into `suspend` — so each waits for a context switch the other
> can only perform after its own wait — instrumented, 4 of 4 stalls show
> w-0 resuming w-1's current fiber and w-1 resuming w-0's. Reproducer
> (`ping.cr`, 29 lines, no GC calls needed): 0.5–4 runs in 100 depending on
> host load, `./ping 2 4000`. Unchanged on master (`resume` is identical).
> The `OPTIMIZE` note in `resume` is the fix: giving up after 1 000 spins,
> re-enqueueing the target and switching to the scheduler's main fiber took
> an interleaved A/B from 18 stalls in 2 500 runs to 0 in 2 500; as a patch
> to the stdlib (`resume-requeue.patch`, against master), 72 → 0 in 2 500
> on the unmodified reproducer.
