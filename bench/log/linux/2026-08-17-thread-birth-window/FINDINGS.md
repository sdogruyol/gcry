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

## An attempted fix, measured and reverted

The cheap half of what Boehm does: hold Crystal's thread-list lock across
`pthread_create`. `stop_world` takes the same lock before it suspends anything,
so a collection cannot *begin* while a thread is being created — the hope being
that this shrinks the window to nothing worth measuring.

It does neither. A/B on the census workload, 16 workers, ten runs each:

| | crashes | runs showing a census gap |
|---|---|---|
| without the lock | **0/10** | 3/10 |
| with the lock | **3/10** | 3/10 |

The gap rate does not move — a run still reports *"the OS reports 18 thread(s)
and Crystal's list yielded 16"* — and the arm **introduces crashes**, in
`stop_world` itself. That is consistent with what the lock actually does: the
new thread blocks on the same mutex inside its own `start`, so at the moment the
creator releases it there is still a thread that exists, is not in the list, and
is now racing the collector for the lock. The window moved; it did not close.
And parking a starting thread on a mutex the collector also takes puts it in a
state the suspend path does not expect.

Written, measured, reverted — the same disposition as the 2026-08-15 grace list.
What it rules out is worth keeping: **the window cannot be closed from the
creating side alone.** gcry needs the other half too — its own record of the
thread, made before user code runs, which is what `GC_pthread_create` gives
Boehm. A trampoline that registers `pthread_self()` and only then calls the real
start routine, with `stop_world` suspending the union of that record and
Crystal's list, is the shape that can work; the census is the acceptance test
and currently reads 3/10.

## The second attempt: the record works, the trampoline does not

The other half — what `GC_pthread_create` gives Boehm. `GC.pthread_create` passes
a trampoline that records `pthread_self()` in a fixed staging table and only
then calls the real start routine, so gcry knows the thread exists from its
first instruction. `stop_world` drops a staged entry once the thread turns up in
Crystal's list, leaving exactly the not-yet-published set. Nothing about what the
collector *suspends* was changed: the recording half first, verified before
anything acts on it.

**The record is right.** Every census gap observed with it on was accounted for
exactly:

```
gcry: thread census — the OS reports 14 thread(s) and Crystal's list yielded 13,
      so 1 thread(s) are outside Crystal's list. gcry has staged 1 of them,
      so it knows they exist. collection 0
```

Seven such reports, every one `staged >= gap`, and `staged_overflows` zero. So a
record made before user code does capture the window the census measures — the
approach is sound.

**The implementation is not.** A/B on the same workload, 16 workers, ten runs:

| | crashes |
|---|---|
| without the trampoline | **0/10** |
| with the trampoline | **8/10** |

It destabilises thread startup outright. Reverted.

One thing was learned on the way and is worth keeping, because it cost a hang to
find: **the staging table's class variables must be eager.** With
`@@staged_count = Atomic(Int32).new(0)`, the first process to start a thread
hung — a class variable with an initializer is set up lazily behind a guard, and
the first access happens on a pthread that has not finished starting. The same
trampoline with the staging call removed ran clean, which is what isolated it.
Cleared explicitly from `GC.init` instead, the hang went away and the crashes
above are a separate, later problem.

Candidates for that separate problem, none of them measured: the extra frame
changes what Crystal's `stack_address` derives for the new thread; the trampoline
runs before Crystal's per-thread runtime setup; the slot claim is deliberately
racy and sixteen workers start at once; or gcry's stack-bounds snapshot now
reaches a thread whose Crystal-side state is half-built.

## The third attempt lands: record from the creating side

Same record, different delivery. `GC.pthread_create` stages the handle
`pthread_create` just wrote, on the **creating** thread, with no trampoline and
no new frame on the new one; `stop_world` releases the entry when the thread
turns up in Crystal's list.

| | crashes (20 runs, 16 workers) | census gaps covered |
|---|---|---|
| without the record | **0/20** | — |
| trampoline (attempt 2) | 8/10 | every one |
| **creating side** | **0/20** | **every one** |

Every gap the census reported with it on read `staged >= gap`:

```
the OS reports 18 thread(s) and Crystal's list yielded 17, so 1 thread(s) are
outside Crystal's list; gcry has staged 1 of them, so it knows they exist.
```

An earlier 2-in-10 reading on this arm did not survive a larger sample; at n=20
it is 0. That is worth stating plainly because at n=10 it looked like the same
failure as the trampoline, and it was not.

**What this does and does not buy.** gcry now has a record of every thread from
the moment its handle exists, and the record demonstrably accounts for the
window the census measures. It still does **not** change what `stop_world`
suspends or what the scan walks — deliberately, because two attempts at this
defect have changed collector behaviour and broken it. Acting on the record is
the next step, and it now has a foundation that is measured rather than assumed.

The placement leaves the interval *inside* `pthread_create` uncovered, which
only a trampoline reaches. The census is the instrument that will say whether
that residue matters: gaps it cannot account for will report
"fewer than the gap — at least one is unrecorded".

Gated in `process_spec`: the hook must have run (`staged_total` grows) and
nothing may be left staged once threads are published, both broken on purpose
and observed red.

## Acting on the record: `GCRY_STAGED_WAIT=1`

The record's whole point is to make the window actionable. The least invasive
way to act on it is to **wait**: before stopping anything, give a thread that
exists but has not published itself a moment to do so. It changes nothing about
what is suspended or scanned — the two attempts that did change those broke the
collector — it only declines to start stopping while a thread is known to be
invisible.

Two things about the placement are load-bearing:

- **Before `Thread.lock`.** A starting thread publishes from `Thread#start`,
  which takes that very mutex. Waiting while holding it would deadlock by
  construction: the thread cannot do the thing being waited for.
- **The wait must drain published entries itself.** The first version did not,
  and could not have worked: staging entries were released only by
  `stop_world`'s own walk, which runs *after* the wait, so the count could not
  fall while the wait watched it. Measured: **68 waits, 68 timeouts, every
  one** — and the census gap closed anyway, which made it look like the wait
  worked when what worked was the 2000-pause delay. Draining inside the loop
  fixed it: **~140 waits since, zero timeouts.**

Measured, 16 workers, 160 collections a run, census on:

| | crashes | runs with a census gap |
|---|---|---|
| without the wait | **6/60** | 3/30 in the batch where any appeared |
| with the wait | **0/60** | **0/30** |

Fisher exact on the crash counts gives p ≈ 0.03. That is a real signal and it is
not proof of a fix: 0 of 60 is consistent with a large reduction as well as with
elimination, and this is one workload on one host.

Cost is near zero — 69 waits over ~4 800 collections, i.e. it fires on about
1.4% of them, and only while a thread is starting.

**A timeout drops the staged entries.** A thread that dies before publishing
would otherwise leave a record nothing releases, and every later collection
would pay the full spin and time out again — a permanent cost bought by a thread
that no longer exists. Dropping loses the record, which is the lesser harm, and
`stw_staged_wait_timeouts` counts it.

**On by default**, and that is not the cautious choice, so here is the reasoning.

The local repro is dead — `nested_spawn_uaf` 0/23 and `ec_queue_audit` 0/25 — so
CI is the only place this defect is still observed, and **a knob nobody sets is
never observed at all**. Left off, the question that matters most would stay
unanswered indefinitely: not whether the wait helps the thread family, which is
measured, but whether it also closes the **`Fiber` family** — the `makecontext`
poison crashes on a `Deque(Fiber::Stack)` buffer, which has never been shown to
share this window.

Against that, the evidence for harm is nil: crashes 6/60 → 0/60, census gaps
3/30 → 0/30, ~1.4% of collections wait, every gate and all twelve CI jobs green,
and the timeout safeguard bounds the worst case.

So it ships on, `GCRY_STAGED_WAIT=0` turns it back off, and CI is the test.

- **Worked**: `scheduler-roots`, `ec-queue-audit` and the STW × TLAB property
  test go quiet over ~20 runs, against a base rate of roughly one red in four.
- **Did not**: `ec-queue-audit` keeps dying on `Fiber#makecontext` poison while
  the `pthread_getattr_np` shape disappears — which would say there are two
  windows and only one is closed.

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
