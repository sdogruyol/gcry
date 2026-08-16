# An aarch64 SEGV in `pthread_getattr_np`, in two different gates

2026-08-16. **Seen twice, in two different targets, within four hours.**

| run | commit | target | address |
|---|---|---|---|
| `31933855152` | `e7de946` | `make scheduler-roots` | `0xff42d3800358` |
| `31950823605` | `4645bf7` | `make ec-queue-audit` | `0xff00f1800358` |

Both `test (aarch64 native)`, both the same call chain, and both addresses end
in the same `800358`. A re-run of the first was green, which is why it was
filed as a one-off; the second arrived before that file was a day old. This
section is the correction.

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

## Why it is not the known flake — and why the second occurrence proves it

CI's recurring red is `make ec-queue-audit` dying on gcry's own poison
(`0xdeadf2eedeadf2d0` / `…f2fe`) — the open fiber-creation use-after-free. That
shape crashes *inside the audit's own workload* and the address is the poison.

This shape crashes inside `GC.collect` → `stop_world`, the address is an
ordinary-looking one, and the top frame is libc. The second occurrence landed in
`ec-queue-audit` — the same target as the poison flake — which is what makes the
distinction load-bearing rather than cosmetic: **"ec-queue-audit was red" is not
a diagnosis.** Two different defects fail that step, and only the backtrace
separates them.

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

## The counters are built

Both are in, and gated:

- `Gcry::Platform.stack_bounds_visited` / `.stack_bounds_read` — threads the
  snapshot walked against the subset it got bounds for, on `/gc-stats`. A gap is
  a thread whose pthread mapping the root scan does not have, and it is now
  countable rather than silent — the same shape as the register stubs v0.19.0
  closed.
- `Gcry::Platform.stack_bounds_in_flight` — the `pthread_t` being queried,
  non-zero only while `pthread_getattr_np` is running. The SIGSEGV report reads
  it first, before anything about the faulting address, so a repeat of this
  crash says **which thread** instead of leaving a libc frame.

Gated by `process_spec` (Linux; Darwin queries the descriptor at lookup time and
reports zeros by design, so the same assertion there would be red on a platform
that is working). Broken on purpose and observed red: making
`pthread_stack_bounds` return nil gives `visited=96, read=0` and fails the spec.

## What would settle it

The snapshot loop is `Thread.unsafe_each { |t| snapshot_pthread_stack_bounds(t.to_unsafe) }`.
Two facts would separate "exited thread" from "something else", and both are
cheap:

- count the threads the snapshot visits and the bounds it successfully reads,
  per collection, and expose the pair — a visit that returns nothing is already
  the shape the v0.19.0 register work was about;
- record the `pthread_t` the loop is on before the call, so a fault names the
  thread rather than the libc frame.

Both are now built and gated (above). The next occurrence should print the
thread id and the visited/read pair before the address line.

## One more thing the second run showed

The SIGSEGV report printed, on **aarch64**:

> the kernel reported address 0. On x86_64 that is also what a *non-canonical*
> dereference looks like …

The reasoning is x86_64-specific and the text says so, but it is being printed
on a platform where it does not apply. Small, and worth fixing while the file is
open: a diagnostic that explains the wrong architecture is how a reader gets
sent down the wrong path.

## And the sighting the same day wasted

Run `31953213205`, the next one, failed the *same step* on the **other** defect —
the open use-after-free — and the report could only say:

> the poison is untagged, so it names no block. `GCRY_POISON_TAG=1` writes the
> freed block's address into the poison and this line becomes the block that was
> freed

`make ec-queue-audit` was running `GCRY_POISON_FREED=1`. The tag costs nothing
extra — it is written by the same memset — and the local repro has gone quiet, so
CI is currently the only place this defect is observed. Both the gate and the
5 h soak arm now run `GCRY_POISON_HOLDERS=1` instead, which implies the poison,
the tag, the crash report and the holder search. The next CI catch names the
block, its size, whether the sweep or an explicit free released it, and what
still points at it.

## Status

Open, **2 occurrences**, both aarch64, both in CI, in two different gates. Still
not reproduced on demand and never seen outside CI. It is no longer a one-off,
so the two counters proposed above are worth building rather than merely
proposing — and until they exist, a red `ec-queue-audit` on aarch64 has to be
read from its backtrace, not from its name.
