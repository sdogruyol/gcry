# `make scheduler-roots` SEGV'd on aarch64, inside `pthread_getattr_np`

2026-08-16, CI run `31933855152`, job `test (aarch64 native)`, commit `e7de946`.
**Seen once. A re-run of the same job on the same commit was green.** Recorded
because it is the first of its shape and a re-run erasing it is how a defect
gets rediscovered from scratch six weeks later.

## What happened

```
Invalid memory access (signal 11) at address 0xff42d3800358
  … pthread_getattr_np +84 in /lib/aarch64-linux-gnu/libc.so.6
  → Gcry::Platform::pthread_stack_bounds
  → Gcry::Platform::snapshot_pthread_stack_bounds
  → Gcry::Heap#stop_world
  → Gcry::Heap#run_collection → #collect → GC::collect
  → run<Bool> in bin/scheduler_roots
make: *** [Makefile:247: scheduler-roots] Error 11
```

## Why it is not the known flake

CI's recurring red is `make ec-queue-audit` dying on gcry's own poison
(`0xdeadf2eedeadf2d0`) — the open fiber-creation use-after-free. This is a
different target, a different call, and a different address. Across the last 40
CI runs every other failure resolved to `ec-queue-audit`; `scheduler-roots` had
never failed.

| recent red runs | failing target |
|---|---|
| 31933855152 | **`scheduler-roots`** ← this one |
| 31931064682, 31901992333, 31901300298, 31886802497, 31871253977, 31868397807 | `ec-queue-audit` |

## Why it is not a deadlock, and what that leaves

The snapshot is taken **before** the suspend signals go out, under `Thread.lock`,
and the comment above it says why: `pthread_getattr_np` locks the *target's*
descriptor, so asking it about an already-frozen thread wedged the collector —
18 of 150 starts, fixed by moving the call out of the suspension window
(`bench/stw_startup_hang.cr`). That fix is not what broke here: this is a
**SIGSEGV inside libc**, not a hang.

What is left is the descriptor itself. `pthread_getattr_np` on a `pthread_t`
whose thread has exited reads freed thread-descriptor memory. `Thread.lock` is
held, so Crystal's list is not being mutated under the walk — but the list
holding a `Thread` whose pthread has already exited is not something the lock
prevents. That makes it the same family as `fix/stw-libc-under-suspension`:
gcry asking libc about a thread whose lifetime it does not control.

## What would settle it

The snapshot loop is `Thread.unsafe_each { |t| snapshot_pthread_stack_bounds(t.to_unsafe) }`.
Two facts would separate "exited thread" from "something else", and both are
cheap:

- count the threads the snapshot visits and the bounds it successfully reads,
  per collection, and expose the pair — a visit that returns nothing is already
  the shape the v0.19.0 register work was about;
- record the `pthread_t` the loop is on before the call, so a fault names the
  thread rather than the libc frame.

Neither is a gate on its own. `make scheduler-roots` already runs on all three
platforms with a CI job; if this recurs, the counters make the next occurrence
say something instead of leaving one hex number.

## Status

Open, unreproduced, 1 occurrence in 40+ runs. Not on the v0.20.0 board as a
release blocker — it has never been seen outside CI and never twice — but on the
board as an observation, because the alternative is that the next one is also
"the first of its shape".
