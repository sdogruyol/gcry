# A use-after-free in fiber creation, and it reproduces in seconds

**Date:** 2026-08-15 · host: WSL2 x86_64 **idle**, Crystal 1.22.0-dev

The 2026-08-10 soak SEGV took **1h24m** to arrive, once. That rate is the whole
reason ROADMAP carries "make the soak reproducible enough to bisect": a candidate
fix and a quiet run are the same observation at one crash per five hours.

There is now a use-after-free of the same family that reproduces in **seconds**.

## It was not found by looking for it

`make ec-queue-audit` went red three times today — aarch64 at 06:01, Darwin at
12:58, x86_64 at 18:51. It reads like a flaky gate, and the gate does plant
corruption on purpose, so the obvious reading was that its own manufactured
value was coming home.

Two things said otherwise.

**Where the output stops.** Every crash cut off after `audit: on/off` and before
`slots walked over 8 collections` — inside arm 1's churn, which runs *before* the
harness plants anything.

**What the crash said.** `GCRY_POISON_FREED=1` and `GCRY_SEGV_REPORT=1` were
added to that gate earlier the same day, for exactly this:

```
gcry: SIGSEGV at 0x0 — gcry's freed-block poison (GCRY_POISON_FREED) is in the
faulting context. Something followed a pointer read out of a block that had
already been freed: a use-after-free, not a wild pointer
  … Fiber#makecontext<Pointer(Pointer(Void)), Proc(Fiber, Nil)>
  … Fiber#initialize<Nil, Fiber::Stack, Fiber::ExecutionContext::Parallel, …>
```

On 2026-08-10 the same class of crash left `0x7f1700000149` and nothing else, and
three readings of it were argued for a day. This one classified itself.

## Stripped to the churn

`bench/nested_spawn_uaf.cr` is arm 1 alone: a fiber that spawns a fiber and then
yields, 64 of them per round, 8 collections per round, one context.

| build | crashes |
|---|---|
| gcry, `-Dgc_none` | **16 in 25 runs** |
| Boehm, same file | **0 in 25 runs** |

Same program, same compiler, same workload. **The collector is the subject**, not
Crystal's execution context — that control is what makes the rest of this worth
writing down.

## It does not need parallelism

| workers | crashes in 12 runs |
|---|---|
| 1 | 7 |
| 2 | 7 |
| 4 | 5 |

A single-worker context is enough. That rules out a race *between* workers and
leaves the collector's view of a fiber being constructed while a collection runs.
It also makes the defect far cheaper to chase than the soak ever was: no
parallelism to reason about, one mutator, ~1 in 2 runs.

## Rates, for calibration

| where | rate |
|---|---|
| 2026-08-10 soak | 1 crash in 1h24m, once |
| `make ec-queue-audit` | 1 in 300 local runs |
| this reproducer | ~16 in 25 runs, seconds each |

## What is not claimed

That this **is** the 2026-08-10 SEGV. Same family — a block freed while something
still points at it, inside the Parallel scheduler's world — but that crash was in
`quick_dequeue?` on a queue slot, and this one is in `makecontext` on a fiber
under construction. Whether one explains the other is the next question, and it
is now a question that can be asked of a binary that fails in seconds.

## Narrowed

Each row is 12 runs at `WORKERS=1 ROUNDS=100` unless stated, on the idle host.

| variable | result |
|---|---|
| `COLLECTS=0` (no collection) | **0/10** — the defect needs a collection |
| `COLLECTS=0` + `GCRY_DISABLE_AUTO` | 0/10 |
| plain `spawn` (default context) | **0/12** — needs an *explicitly created* context |
| `NEST=0` (spawn from the main thread) | 8/10 — nesting is not required |
| no `Channel` (atomic counter instead) | 8/12 — the Channel is not the subject |
| `WORKERS=1` / `2` / `4` | 7/12, 7/12, 5/12 — parallelism is not required |
| `GCRY_SOUND=1` | 10/12 — not one of the soundness levers |
| `GCRY_DISABLE_NURSERY` | 9/12 |
| `GCRY_DISABLE_TYPE_ID_GATE` | 12/12 |
| `GCRY_DISABLE_SP_CLAMP` | **hangs**, 3 of 3 — a different failure, not measured here |
| `GCRY_DISABLE_TIGHT_GROW` | 11/12 |

So the minimal shape is: **an explicitly created `Fiber::ExecutionContext::Parallel`,
fibers spawned on it, collections underneath.** No parallelism, no nesting, no
channel, and no known-unsound option involved.

## It is a real use-after-free, not a poison artifact

`GCRY_POISON_FREED=1` is required to see it: without it, **0 in 12**. That raises
the obvious suspicion that poisoning is itself the bug — the repo already names
that hazard, since a freed block that is poisoned but still counted "clean" would
have `malloc` hand out `0xdeadf2ee…` where a caller asked for zeroes.

Measured, and it is not that. 40 rounds of 3 000 allocate-free-collect cycles
across twelve size classes, then 3 000 cleared allocations checked word by word:

    cleared allocations checked=120000 holding poison=0

So the poison is not being handed out. It is being *read through a stale
pointer* — which is what it exists for. The alarming half follows: **without
poison this workload does not crash.** It reads a freed block's old contents,
finds something plausible, and carries on. Whatever it corrupts, it corrupts
quietly.

## A correction: the age of this defect is not known

An earlier pass here reported `v0.19.0` clean and bisected the first bad commit
to `8e7d10e`. That result is void, and the reason is worth keeping: `8e7d10e` is
the commit that *introduced* `GCRY_POISON_FREED`. Every older build was measured
with the knob set and no feature behind it, so what the bisect actually located
was the arrival of the instrument, not the arrival of the defect. Since the
workload is silent without poison, dating this defect needs a different method
than running the reproducer against old commits.

## Where the hunt stands

No option removes it. Several halve it, which is itself the shape of the answer:

| arm | rate |
|---|---|
| baseline | 13/20, 15/25, 6/12 across batches |
| `GCRY_STACK_LOW_WATER=0` | 8/20 |
| `GCRY_DISABLE_LAYOUT=1` | 3/12 |
| `GCRY_DISABLE_BLACKLIST=1` | 3/12 |
| root `StackPool@deque` explicitly | 9/25 against 15/25 |
| `GCRY_INTERIOR=1` | 5/12 |
| `GCRY_UNALIGNED_CANDIDATES=1` | 7/12 |
| context in a constant (static root) not a local | 7/20 — no change |
| collect only after every fiber finished (`QUIESCE`) | 7/20 — no change |

Two of those rows do real work.

**It is not a race with fiber creation.** Letting every fiber finish before
collecting, and only then spawning the next round, leaves the rate where it was.
So the sequence is: fibers run to completion → a collection → the *next* spawn
crashes. The collection frees something the next `checkout` needs.

**It is not how the context is rooted.** Moving the context from a local into a
constant — from the stack into static data — changes nothing, so the "explicitly
created context" requirement is not a rooting question about the context object.

What that leaves is the path a *finished* fiber's stack takes: `Fiber#run`
releases it into `Fiber::StackPool@deque`, a collection runs, and the next
`checkout` reads it back. Explicitly rooting that deque halves the rate, which
points at it without convicting it — halving is what timing changes do too, and
every other row here halves something.

**The next instrument is not another knob**: it is making the collector say
*which block* it freed, so the poison the crash reads can be traced to the free
that wrote it. That instrument now exists — see below.

## `GCRY_POISON_TAG=1`, and the block it names

`POISON_WORD` is one constant, so every poisoned block reads alike and a crash
that finds it can say "a use-after-free" and nothing more. The tagged poison
writes `0xDEAD` in bits 63:48 and **the freed block's own address** in the low 48
— still non-canonical, so it faults identically, and 48 bits is the whole of an
x86_64 user address, so nothing is lost. `segv_report` then describes that
address against the heap's tables exactly as it describes a faulting one.

The first crash it caught:

```
gcry: SIGSEGV at 0x0 — gcry's freed-block poison … a use-after-free
gcry: the free that wrote it was of the block at 0x735a075dec88, still FREE, size 768, flags 0x1
```

40 crashes, and the sizes are not scattered:

| size | count |
|---|---|
| 3072 | 11 |
| 1536 | 11 |
| 768 | 9 |
| 384 | 4 |

`Fiber::Stack` is 24 bytes (`Void*`, `Void*`, `Int32`, `Bool`, aligned). Those
four sizes are **24 x 16, 32, 64, 128** — the capacity-doubling sequence of a
`Deque(Fiber::Stack)`. Every one is `still FREE`, so none was reissued: the pool
read back its own freed buffer.

**The block is `Fiber::StackPool`'s deque buffer.** `Fiber#run` releases a
finished fiber's stack into it, a collection frees the buffer, and the next
`checkout` reads a `Fiber::Stack` whose `pointer` is poison — which is exactly
where `makecontext` writes.

## The trigger: the deque's resize, and only that

Everything else moved the rate. This removes it.

Pre-grow the pool so the deque never resizes during the workload — spawn 512
fibers that all block at once, so 512 stacks are allocated and then released
together, taking the deque to `capacity=512` — and then run the same 100 rounds
of 64:

| | crashes |
|---|---|
| pool pre-grown to 512 (no resize during the run) | **0 in 20** |
| not pre-grown | 6 in 15, 6 in 20, 13 in 20 across batches |

A first attempt at this arm was wrong and is worth recording: spawning 1024
fibers sequentially does *not* grow the pool, because with one worker each fiber
finishes and hands its stack straight to the next, so the deque never holds more
than a few. The capacity line said `kapasite=16` while the arm claimed to have
warmed 1024. The fix is to keep them all alive at once behind a gate.

## What is not the cause

- **Not a reachability failure of the current buffer.** After each collect, read
  the pool's live `@buffer` and ask `HEAP.live?`: **0 dead in 4 800 checks**, so
  gcry never frees the buffer the deque is actually using.
- **Not the window inside `Heap#realloc`.** That method already pins the old
  block with `add_root` and suppresses collection across the `allocate`. Moving
  the `copy_from` inside the suppressed region as well: 5/20 against a 6/20
  baseline — no effect.

## Where that leaves it

The block the crash reads is a buffer the deque **abandoned during a resize** —
not the one it is using. gcry freed it correctly; something still reads it. Under
Boehm the same stale read is harmless, because a conservative collector that sees
the stale pointer keeps the old buffer alive and its contents are still valid
`Fiber::Stack` entries. Under gcry the block is freed and poisoned, so the same
read is fatal.

Whether the retained pointer is Crystal's (`Deque#resize_to_capacity` sets
`@capacity` before `@buffer`, and `Fiber::StackPool` reads `@deque.empty?` and
`lazy_size` outside its lock) or something gcry does with it, this file does not
say — and the difference matters, because only one of those is gcry's to fix.

## Not a CI gate

Deliberately. It fails most runs, which is the finding; a gate that is always red
gates nothing, and wiring it in would bury every other signal in the job. `make
nested-spawn-uaf` runs it. It becomes the regression test when the defect is
fixed.
