# `stop_world` hangs waiting for a worker that has never been scheduled

**Date:** 2026-08-10 · host: R9-9950X (16C/32T), WSL2, Crystal `c361ac6e7`,
`-Dgc_none -Dpreview_mt -Dexecution_context`, EC parallelism 4 · tip @ `d36effe`

Found while building `bench/scrub_midswap.cr`. It is **not** a scrub bug — that
was ruled out by measurement, see the bisect below.

## Symptom

The process wedges inside `GC.collect` and never returns. No crash, no output,
no diagnostic. Four threads, identical every time:

```
tid A  comm=<program>  state=S  wchan=sigsuspend        utime=9     suspended, acked
tid B  comm=SYSMON     state=R  wchan=0                 utime=533   collector, spinning
tid C  comm=DEFAULT-1  state=S  wchan=futex_wait_queue  utime=0     never ran
tid D  comm=SYSMON     state=S  wchan=sigsuspend        utime=0     suspended, acked
```

`utime=0` on `DEFAULT-1` is the whole finding: that thread has never executed an
instruction, so it cannot have taken the SIGPWR, and the pending signal cannot be
handled until it is scheduled. It is parked in the futex of its own startup
handshake — whose other side is a thread STW has already frozen. Three-way: the
worker waits on a suspended thread, the collector waits on the worker.

(Two threads report `comm=SYSMON` because Linux gives a new thread its creator's
name until it sets its own, so tid B is a worker spawned by the Monitor.
`stw_signal_exempt?` reads Crystal's `Thread#@name`, not `comm`, so this is
cosmetic — but it is why the dump looks impossible at first.)

## Where

`Heap#stop_world`, `src/gcry/collect_stw.cr:85-91`:

```crystal
Thread.unsafe_each do |thread|
  next if thread == current_thread
  next if stw_signal_exempt?(thread)
  until thread.@suspended.get
    Intrinsics.pause
  end
end
```

Unbounded, no re-signal, no timeout, no warning. Any thread in
`Thread.unsafe_each` that cannot yet run wedges the collection permanently.

## Bisect by ingredient

`bench/stw_startup_hang.cr` (`make stw-startup-hang`), each row N child
processes, 6 s ceiling per child:

| child body | hung |
|------------|-----:|
| `resize(4)` + `GC.collect` | **0 of 200** |
| `resize(4)` + a fiber that never yields + `GC.collect` | **18 of 150 (12%)** |
| + scrub on and audit on | no additional effect |

So the trigger is a fiber that takes a worker and does not give it back while the
first collection runs. The scrub was in the shape that found it, not in the cause
— which is also why the mid-swap harness sees it: that harness parks a fiber on a
worker and collects immediately, i.e. it is the hanging shape by construction.
It retries such children and reports the count rather than attributing them to
the guard.

Rate varies with how soon the first collect follows `resize`: observed 2/21,
2/36, 4/186 and 3/40 in earlier loops before the ingredient was isolated. Treat
it as "a few percent to 12% of starts in this window", not as a number.

## Why it matters

An EC application whose first collection lands within milliseconds of raising
parallelism can stop dead at startup with no output at all. Kemal/acik at EC4
allocate enough during boot to reach a first collect early, and a hang there
looks like a deployment that never came up rather than a GC bug.

It is the same family as the hang already documented in `collect_stw.cr`
(`GCRY_STRESS`: main=`futex_do_wait`, SYSMON=`sigsuspend`), closed then by making
SYSMON signal-exempt. A worker still inside startup is a second member of that
family and is not exempt.

## Not this

- **Not the acikturkiye SIGSEGV at 0x4.** This hangs; it does not crash, and it
  needs EC parallelism > 1. It says nothing about that crash either way.
- **Not the scrub.** 0 of 200 with the scrub on and no spinner; 18 of 150 with
  the scrub off and a spinner.

## Next

Candidate fixes, none implemented:

1. Bound the ack wait and re-signal on expiry — cheapest, and it converts a hang
   into progress, but a thread that cannot run still cannot ack, so it needs
   either (2) or (3) to terminate.
2. Skip threads that have not reached a first checkpoint, and treat them as
   already stopped — a thread that has never run holds no mutator state, so this
   looks sound, but "has never run" has to be observable from the collector.
3. Have `resize` publish a worker's `Thread` only once it can take a signal —
   closes the window at the source, but it is Crystal-side, not gcry-side.

Whatever lands, `make stw-startup-hang` is the gate: it is red today on purpose.
