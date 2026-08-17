# The missing root is the stack in flight

> **RETRACTED, same day.** The arm measured here is real and its zero is real,
> but the name on it is wrong. The arm rooted *every* stack-shaped mapping no
> fiber and no pool claimed, and a later coverage audit showed 330 of those per
> run were the stack Crystal parks on a `Thread` when a fiber **terminates**,
> against a handful genuinely in flight. A fix built on the in-flight reading —
> a hook on `Fiber::StackPool#checkout` — measured 13/24 against 8/24, which is
> nothing, and was deleted. Rooting the dying-fiber stack alone is 0/24. See
> `bench/log/linux/2026-08-17-dead-fiber-stack-roots/FINDINGS.md`; what follows
> stands only as the measurement that got the hunt to the right neighbourhood.

2026-08-17, the same day as
`bench/log/linux/2026-08-17-address-space-audit/FINDINGS.md`, which found the
dying `Deque(Fiber::Stack)` buffer's address on two kinds of stack nothing
scans: **pooled** (sitting in a `Fiber::StackPool` deque) and **in flight**
(checked out of the pool, not yet attached to a published `Fiber`). It could not
say which of the two mattered — a pooled stack's frames belong to a fiber that
has finished, so the same word may be a dead copy.

This is the answer, and it is one of them.

## Measured

`bench/nested_spawn_uaf.cr` at `ROUNDS=20 FIBERS=64`, with
`GCRY_POISON_FREED=1 GCRY_THREAD_CENSUS=1` — poison is what turns the
use-after-free into a fault, and the census is what keeps the repro live. Five
arms, **interleaved round-robin**, n=24 each, so host drift lands on all five:

| arm | crashes |
|---|---|
| control | **10/24** |
| pooled stacks, rooted | 20/24 |
| pooled stacks, walked and offered nothing | 13/24 |
| **in-flight stacks, rooted** | **0/24** |
| in-flight stacks, walked and offered nothing | 14/24 |

Confirmation batch, control against the one arm that moved, interleaved, n=20:
**control 10/20, in-flight rooted 0/20**. Combined: **20/44 against 0/44**.

## Why the twin arms are the whole design

The birth grace went to zero too, and its effect turned out not to be the
rooting — rooting `null` was just as effective, which retired the explanation
and left only a timing artefact. So each window here got two arms that walk
exactly the same memory and differ **only** in whether the words are handed to
the mark.

They separate cleanly. In-flight rooting is 0/24 while in-flight walking is
14/24, above control. Nothing about parsing `/proc/self/maps` per collection, or
touching 4 M words of stack, moves the crash rate; offering those words to the
mark takes it to zero. The pooled pair does not separate at all: rooting them is
20/24, worse than control.

So the pooled hits from the audit were stale copies, as suspected, and the live
one is the stack in flight.

## And it is not retention

An arm that keeps everything alive also stops crashing. It does not look like
this:

| | heap_size | live_objects | collections |
|---|---|---|---|
| control | 2 428 928 | 982 | 160 |
| in-flight rooted | 2 428 928 | 893 | 160 |
| pooled rooted | 2 428 928 | 1 022 | 160 |

Same heap, same number of collections, no more objects surviving. The arm adds
roots that are *live*, not roots that are *many*.

## The mechanism, stated plainly

`Fiber.new` calls `stack_pool.checkout`, which shifts a stack out of the pool's
deque, and only afterwards publishes the `Fiber`. In between:

- the stack belongs to no `Fiber`, so `Fiber.unsafe_each` does not yield it and
  no root scan reaches it;
- `makecontext` has already written the new fiber's first frame onto it, holding
  the pointers the fiber will start from.

A collection landing in that window frees what those pointers point at. The
fiber then starts and uses freed memory — `Fiber#initialize` → `makecontext`,
which is exactly where 15 of 16 crashes in this family die.

## What this arm is not

It is an instrument, not a fix. It finds in-flight stacks by walking
`/proc/self/maps` every collection and taking every readable mapping of exactly
`STACK_SIZE - PAGE_SIZE` that no fiber and no pool claims. That is Linux-only
(`Platform.each_map_region` answers `false` on Darwin), it costs a maps parse
per collection, and its shape test would pick up an unrelated mapping of the
same size.

A shippable fix should learn the same fact from the source instead: reopen
`Fiber::StackPool` and record the stack between `checkout` and `release`, which
is O(1), exact, and portable. `src/gcry/monitor_gate.cr` is the precedent for
reopening a Crystal class from gcry.

## Reproducing

```
crystal build -Dgc_none bench/nested_spawn_uaf.cr -o bin/nested_spawn_uaf
ROUNDS=20 FIBERS=64 GCRY_POISON_FREED=1 GCRY_THREAD_CENSUS=1 \
  GCRY_INFLIGHT_STACK_ROOTS=1 ./bin/nested_spawn_uaf
```

Knobs: `GCRY_INFLIGHT_STACK_ROOTS`, `GCRY_INFLIGHT_STACK_NOROOT`,
`GCRY_POOLED_STACK_ROOTS`, `GCRY_POOLED_STACK_NOROOT`
(`src/gcry/unowned_stack_roots.cr`). Each arm counts the stacks it walked and
the words it offered, printed by the bench, so a null result cannot be an arm
that never ran.
