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

So it is the scheduler alone. A collector's stop-the-world pauses can only
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
> can only perform after its own wait. Reproducer (`ping.cr`, 29 lines, no
> GC calls needed): about 2–4 runs in 100 on a loaded 12-core host,
> `./ping 2 4000`. The `OPTIMIZE` note in `resume` (abort and re-enqueue after
> N attempts) would break the cycle.
