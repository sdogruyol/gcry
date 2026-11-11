# "process GC thread staging records every thread it creates" read 0 on Crystal 1.22.2

CI run 41228348742 at `e3a2de7a`, job `specs (x86_64, crystal 1.22.2)` (124617203329): inside
`make bitmap-marks-freelist`, `GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none
-Dgcry_block_headers process_spec` failed one example, `(Gcry::Platform.staged_total -
before).should be > 0` → `Expected 0 to be GreaterThan 0`. The two `process_spec` steps before it in
the same job, on the same compiler, passed it.

## Not the compiler, and not a staging miss

Crystal 1.22.0 → 1.22.2 changes nothing under `src/fiber/execution_context/` except one line of
`isolated.cr` (`done = true` → `done = false` in `wait_for`). `Parallel`, its scheduler, the
`ThreadPool` and the `Monitor` are byte-identical, and the behaviour below reproduces on 1.21.0 as on
1.22.2.

Every thread that went through `pthread_create` was staged. The example created none.

## The example assumed a new execution context creates threads

A `Parallel` context starts its schedulers lazily (`wake_scheduler`), and each one takes its thread
from `ExecutionContext.thread_pool.checkout`, which hands out a **parked** thread when it has one and
calls `Thread.new` only when it does not. The pool is not empty in a `process_spec` run as a rule:

- the execution-context monitor (SYSMON, every 10 ms) hands a scheduler it finds inside
  `Fiber.syscall` — `open(2)` in the polling event loop, `flock`, `getaddrinfo` — to another thread
  (`transfer_schedulers_blocked_on_syscall`), and the thread it leaves checks itself into the pool
  when the call returns (`Scheduler#syscall` → `thread_pool.checkin`);
- that thread stays parked for `thread_keepalive` (5 minutes), and **for good** when it is the
  process's main thread (`ThreadPool#can_terminate?` is false for it). `spec/spec_helper.cr` already
  records the move itself: one per ~1 000–3 000 `File.open` on the main fiber on Darwin.

So whether the example's context created a thread depended on whether such a move had happened in the
5 minutes before it (or ever, for the main thread), and on whether its second scheduler started at
all before four trivial fibers were done. When both of its threads came from the pool, or the second
was never started, `staged_total` did not move.

## Reproduced

`pool_probe.cr` here (raw output in `probe-results.txt`), built with `-Dgc_none` against this
tree. Arms: `control`; `moved` — the main fiber sits 200 ms inside `Fiber.syscall { nanosleep }`
so the monitor moves its scheduler; `seeded` — an `Isolated` context that ends. Then the example's
body, and the fixed example's checks. Five runs per arm per compiler:

| crystal | arm | EC threads reused from the pool | reused thread is the main thread | old example's `staged` | old example | fixed example |
|---|---|---|---|---|---|---|
| 1.21.0 | control | 0 of 5 | — | 2, 2, 2, 2, 2 | 5 pass | 5 pass |
| 1.21.0 | moved | 5 of 5 | 5 of 5 | 1, 1, 1, 1, 1 | 5 pass | 5 pass |
| 1.21.0 | seeded | 5 of 5 | — | 1, 1, 1, 1, 1 | 5 pass | 5 pass |
| 1.22.2 | control | 0 of 5 | — | 2, 2, 2, 2, 2 | 5 pass | 5 pass |
| 1.22.2 | moved | 5 of 5 | 5 of 5 | 1, **0**, 1, 1, 1 | **1 FAIL** | 5 pass |
| 1.22.2 | seeded | 5 of 5 | — | 1, 1, 1, 1, 1 | 5 pass | 5 pass |

An earlier batch of the same probe (old checks only): `moved` read 1, 1, **0** on 1.21.0 and 1,
**0**, 1 on 1.22.2; `control` 2 every time. Once a pool thread runs the context's fibers, the old
example passes only if the second scheduler happens to be started on a new thread; the `0`s are runs
where it was not.

## Fix

The example now counts what it can own:

1. it seeds the pool on purpose (an `Isolated` context whose fiber ends), so the reuse case is the
   one exercised every run rather than once in a while;
2. it records the pthread id each of the context's fibers ran on, and asserts
   `staged_total` grew by **at least the number of those threads that were not on Crystal's list
   before the context existed** — every thread the context created was staged;
3. "the hook ran" moves to a `Thread.new { }.join`, which never goes through the pool, so `> 0` is
   asserted on a thread that is always created.

`staged_total` itself is now an atomic add. It was `&+= 1` from every creating thread, and a
parallel context's schedulers start each other's threads, so two births at once could count as one —
which check 2 would read as a staged thread missing.

## Verification

See `runs.txt`: `process_spec` on 1.21.0 and 1.22.2, default (`-Dgc_none`) and
`GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0 -Dgc_none -Dgcry_block_headers`, and the example alone 12 times per
1.22.2 configuration.
