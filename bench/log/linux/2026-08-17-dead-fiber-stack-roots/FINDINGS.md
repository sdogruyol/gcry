# The missing root is the stack of a fiber that is ending

2026-08-17, later the same day as
`bench/log/linux/2026-08-17-inflight-stack-roots/FINDINGS.md`, which this file
**corrects**. That round measured an arm that rooted every stack-shaped mapping
no fiber and no pool claimed, watched it take the crash rate to zero, and called
the window "the stack in flight — checked out of the pool, not yet attached to a
published `Fiber`". The arm was right. The name was wrong.

## The correction, and how it surfaced

The fix written from that name was a hook on `Fiber::StackPool#checkout` that
recorded exactly the in-flight stacks. Measured against itself disabled,
interleaved, n=24: **13/24 against 8/24**. That is not a result (p≈0.24).

A coverage audit run beside the hook said why. Of the mappings the original arm
rooted, the hook accounted for a handful; **330 were something else** — the
stack Crystal parks on a `Thread` when a fiber terminates. Excluding those from
the audit dropped "unaccounted for" from 330 to 2. The arm's zero had never come
from the in-flight window at all; it came from the mass the arm happened to
include.

So the hook was deleted rather than shipped on a maybe, and the window it was
built for is back to unproven.

## Measured

`bench/nested_spawn_uaf.cr`, `ROUNDS=20 FIBERS=64`, with
`GCRY_POISON_FREED=1 GCRY_THREAD_CENSUS=1` — poison is what turns the
use-after-free into a fault, the census is what keeps the repro live. Four arms,
interleaved round-robin, n=24:

| arm | crashes |
|---|---|
| control | 11/24 |
| **dying-fiber stack, rooted** | **0/24** |
| dying-fiber stack, walked and offered nothing | 12/24 |
| dying-fiber stack rooted + the checkout hook | 0/24 |

And the shipped code, after the hook was removed and the file rewritten,
measured again from scratch, interleaved, n=24: **fix off 10/24, fix on 0/24**.

The twin arm is the whole design. The birth grace also went to zero, and its
zero turned out to be timing rather than rooting; here walking the identical
memory and offering nothing leaves the rate at 12/24, above control. The effect
is the rooting.

## Why a dead fiber's stack holds live data

It is not dead yet. Crystal says so in `crystal/system/thread.cr`:

> When a fiber terminates we can't release its stack until we swap context to
> another fiber. We can't free/unmap nor push it to a shared stack pool, that
> would result in a segfault.

`Thread#dying_fiber(fiber)` parks the terminating fiber's stack on the thread
and returns the previous occupant for release. While a stack sits in that slot:

- the `Fiber` that owns it is already gone from the fiber list, so
  `Fiber.unsafe_each` does not yield it and no fiber scan reaches it;
- the thread may still be **executing on it** — that is the entire reason the
  slot exists — and gcry's other-thread scan works from the thread's *pthread*
  stack bounds, which a thread running on a fiber stack is nowhere near.

Neither root source covers it, so anything reachable only from those frames is
unrooted, and a collection landing in the window frees it.

## And it is not retention

An arm that keeps everything alive also stops crashing. This does not:

| | heap_size | live_objects | collections |
|---|---|---|---|
| control | 2 428 928 | 982 | 160 |
| fix on | 2 428 928 | 909 | 160 |

Same heap, same number of collections, no more objects surviving.

## Coverage

`GCRY_UNOWNED_COVERAGE_AUDIT=1` walks `/proc/self/maps` beside the fix and
counts stack-shaped mappings that no fiber, no pool, and no thread's
dying-fiber slot accounts for: **549 accounted for, 4 not**, per run. The four
are not explained. They are few enough not to move a crash rate and too few to
name from counts alone; the next round can label them with the address-space
audit if they matter.

## The shape of the fix

Read `Thread#@dead_fiber_stack` for every thread at root time and scan the top
64 KiB. O(threads), no `/proc`, no size matching, portable to every platform
Crystal runs on. On by default (`GCRY_DEAD_STACK_ROOTS=0` disables it), gated in
`process_spec` in both directions.

The ivar is read directly and never through `dead_fiber_stack?`, which hands the
slot over and clears it: a scan that consumed the thread's recycled stack would
change what the program does, not just what the collector sees.

64 KiB because every hit the address-space audit reported was 968 to 1408 bytes
below the stack top, where `makecontext` writes a fiber's first frame.

## The pause cost is not measurable

Two instruments, both arms interleaved on the same host:

| | p50 | p99 |
|---|---|---|
| `pause_budget --live-mb=20`, off (4 runs) | 18.71–19.23 ms | 26.4–35.5 ms |
| `pause_budget --live-mb=20`, **on** (4 runs) | 18.91–19.92 ms | 22.4–33.9 ms |
| `nested_spawn_uaf`, 16 workers, off (8 runs) | 23.9 ms | 89.9 ms |
| `nested_spawn_uaf`, 16 workers, **on** (8 runs) | 19.9 ms | 60.8 ms |

The ranges overlap completely in the first pair and the second pair favours the
fix, which is not a claim worth making either — a 16-worker fiber workload's
pause is dominated by other phases and the spread is wide. What can be said is
that scanning ~1 300 stack windows a run does not show up. CI's `perf smoke`
gate passed on the same commit.

## And it does not close the other family

The push that carried this fix produced a red `test (aarch64 native)`:
`make ec-queue-audit` died in `pthread_getattr_np` on a **poisoned `pthread_t`**
(`0xdeadff7810b3d738`), with the report naming a 192-byte block freed by an
*explicit* free and since reissued. That is the thread family
(`bench/log/linux/2026-08-16-scheduler-roots-aarch64-segv/FINDINGS.md`), not the
fiber-creation one this closes, and it reproduced on neither the re-run nor any
local batch. The fiber repro at 0/24 says nothing about it.

## Reproducing

```
crystal build -Dgc_none bench/nested_spawn_uaf.cr -o bin/nested_spawn_uaf
ROUNDS=20 FIBERS=64 GCRY_POISON_FREED=1 GCRY_THREAD_CENSUS=1 \
  GCRY_DEAD_STACK_ROOTS=0 ./bin/nested_spawn_uaf   # crashes ~10 in 24
ROUNDS=20 FIBERS=64 GCRY_POISON_FREED=1 GCRY_THREAD_CENSUS=1 \
  ./bin/nested_spawn_uaf                            # 0 in 24
```
