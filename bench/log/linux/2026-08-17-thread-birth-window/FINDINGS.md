# A thread gcry has not heard of yet is not stopped and not scanned

2026-08-17. Follows the fifth occurrence of the aarch64 crash
(`bench/log/linux/2026-08-16-scheduler-roots-aarch64-segv/FINDINGS.md`), which
showed gcry reading a `Thread`'s `@system_handle` out of a **freed, poisoned
block**. This file is what that led to, and it separates what is measured from
what is derived, because only the first part is settled.

## Measured

- The `pthread_t` gcry passed to `pthread_getattr_np` was
  `0xdeadff86af17d738` — `POISON_TAG` in the top 16 bits and the freed block's
  address in the low 48. A `Thread` object's memory had been reclaimed while
  Crystal's thread list still yielded it.
- `GC.pthread_create` in gcry is a **bare passthrough** to `LibC.pthread_create`
  (`src/gcry/gc_override.cr`): no thread registration, no collection
  suppression, no wrapper around the start routine.

## Derived from Crystal 1.21.0's source

The ownership of a worker `Thread` between its allocation and its first
appearance in `Thread.threads`:

- `Fiber::ExecutionContext::Parallel#start_thread` calls
  `ExecutionContext.thread_pool.checkout(scheduler)` and **discards the result**
  — its return type is `Nil`. `Isolated` does the same.
- `ThreadPool#checkout` creates the thread with `Thread.new do |thread| … end`
  and returns it; the object lives in that frame and dies with it.
- The block, which runs on the **new** thread, calls
  `attach(thread, scheduler)` → `scheduler.thread = thread`. That is the first
  heap reference to the object.
- `Thread#start`, also on the new thread, is what pushes it onto
  `Thread.threads`.

So between `pthread_create` returning on the creating side and `attach` running
on the new side, the object's only references are the new thread's own frame and
libc's internal argument slot.

And gcry cannot see either, because **it learns about threads from Crystal's
list**: `stop_world` iterates `Thread.unsafe_each` to suspend, and
`scan_thread_roots` / the stack scans iterate the same list. A thread that
exists at the OS level but has not yet pushed itself is therefore:

- **not suspended** during a collection — it keeps running through the "stopped"
  world, allocating and mutating;
- **not scanned** — neither its stack nor its registers are roots.

That is a structural statement about gcry, independent of this crash, and it is
the shape the v0.19.0 register work was about: a root source the collector
assumes and the platform supplies nothing for. Boehm does not have it because
`GC_pthread_create` wraps the start routine and registers the thread before user
code runs.

## Not reproduced, and the attempts are worth recording

Two attempts to catch a `Thread` being freed under itself, with the new thread
asking `HEAP.live?(self)` as its first action:

| arm | result |
|---|---|
| 200 threads, reference dropped, 3 collections each | **0 freed** |
| 300–40 threads, reference discarded exactly as `start_thread` does, under `GCRY_STRESS` / a 64 KiB threshold | **hangs**, at every size tried, killed at 90–180 s |

The first says the window is not trivially hit; the second says nothing at all,
because a hang in thread creation under frequent collection is *already* a known
shape on this board (`bench/stw_startup_hang.cr`: 18 of 150 starts wedged in
`pthread_getattr_np` before that call was moved out of the suspension window).
Pushing harder would have been chasing a harness artefact.

So: **the mechanism above is a hypothesis with a measured symptom and a
source-derived path, not a reproduction.** It is written down at that strength
deliberately.

## Measured: the window is real, and rare

`GCRY_THREAD_CENSUS=1` counts, at every `stop_world`, what Crystal's list yields
against what `/proc/self/status` says the process has. It has seen the
difference:

```
gcry: thread census — the OS reports 10 thread(s) and Crystal's list yielded 9,
      so 1 thread(s) are running through this stopped world, unscanned.
      collection 4
```

Rate, on a fiber-churn workload with 160 collections per run, six runs per arm:

| workers | runs with a gap | gap collections |
|---|---|---|
| 4 | 0/6 | 0 |
| 8 | 0/6 (1 in an earlier run) | 1 |
| 16 | **2/6** | 2 |

So roughly **one collection in a thousand** has a thread the collector neither
stopped nor scanned, the gap is **one thread**, and it scales with how much
thread creation the workload does — collection 4 in the observed case, i.e.
during worker startup, which is where the argument said it would be.

That is the argument turned into a number. It does **not** show that the window
causes the crash — a thread being unscanned for one collection only matters if
something is reachable solely from it, which is the next question — but it
removes "this is theoretical" as an answer.

`thread_census_checks` / `_gaps` / `_gap_max` / `_unanswered` are on
`/gc-stats`. The last one exists so "no gaps" can never be the result of never
having looked, and the reader returns `nil` rather than 0 when `/proc` cannot
answer, for the same reason. Gated in `process_spec` (Linux; Darwin answers
`nil` by design), broken on purpose and observed red.

## What would settle it

Instrument rather than reproduce. gcry can count what it cannot see:

- at `stop_world`, compare the number of threads Crystal's list yields against
  the number the OS reports for the process (`/proc/self/status:Threads` on
  Linux). A run where those differ has a thread outside the stopped world, and
  the difference is exactly the window this file is about;
- that number is cheap, needs no repro, and turns "a thread can be invisible"
  from an argument into a counter — which is the same move that turned the
  register stubs and the stack-bounds snapshot into gates.

If the counter never differs, the window is theoretical and this file is wrong
about its size. If it does, the fix follows: register the thread with gcry from
`GC.pthread_create` — wrapping the start routine as Boehm does — rather than
waiting for Crystal to publish it.
