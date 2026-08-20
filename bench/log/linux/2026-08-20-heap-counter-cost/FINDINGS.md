# The counters were losing updates to buy a cost that does not exist on x86_64

2026-08-20. `note_alloc_bytes` updated `live_objects`, `total_bytes` and
`bytes_since_gc` with plain `set(get + n)` unless `heap_counters_atomic` was
set, and the comment on that property said why:

> Parallel: Atomic RMW on every alloc/free. EC1 default off — LOCK XADD / CAS on
> the hot path costs Kemal thr; single mutator + rare SYSMON is fine with plain
> get/set.

Both halves of that turn out to be wrong, and in opposite directions.

## The loss is real and large

Four threads, 300 000 allocations each, GC disabled so a sweep cannot recompute
what the increment path did:

| path | allocated | counter moved | lost |
|---|---|---|---|
| plain `set(get + n)` | 1 200 000 | 1 194 277 | **5 723** |
| atomic | 1 200 000 | 1 200 014 | **0** |

(The 14 extra are the threads' own runtime allocations.) `make heap-counters`
requires both rows: the old path must be shown to lose, or the new one's
exactness is just a run that happened not to race.

## What the "cheap" path compiles to

`Atomic#set` defaults to sequentially-consistent ordering. On x86_64 that is not
a plain store:

```
plain_bump   (set(get + n)):   mov ; inc ; xchg %rax, A     ← xchg to memory is locked
atomic_bump  (add(n)):         lock incq A
relaxed_bump (add(n, :relaxed)): lock incq A
```

So the path that loses increments was already paying for a locked instruction
per counter — three of them per allocation — and the atomic path is *fewer*
instructions for the same lock traffic. Measured, three arms interleaved and
pinned to one core, minimum ns per allocation over five rounds:

| plain | atomic (seq_cst) | atomic (relaxed) |
|---|---|---|
| 55.69 | 55.47 | 56.13 |

Within-arm spread is ~3 ns, so the three are indistinguishable. The first
attempt at this measurement ran the arms sequentially and reported 53.08 against
53.43, then 57.25 against 70.34 for the same pair — the machine drifts, and only
interleaving made the numbers comparable.

## And on aarch64 it is the other way round

The same probe cross-compiled to `aarch64-linux-gnu` (baseline codegen, no LSE):

```
plain:   ldar x9, [x8] ; add ; stlr x9, [x8]
atomic:  ldaxr ; add ; stlxr ; cbnz   ← LL/SC retry loop
relaxed: ldxr  ; add ; stxr  ; cbnz   ← LL/SC retry loop
```

There the atomic path is genuinely more work. So the original comment was right
about one architecture and wrong about the other, and a change that simply
turned atomics on everywhere would have been defended with x86_64 numbers and
paid for on ARM.

## What shipped

The counters flip to atomic **when a second thread is created** —
`GC.pthread_create` already runs there for the staging record and the birth
root — which is before that thread can allocate. A single-threaded program keeps
the plain path and pays nothing on either architecture; anything that can race
keeps its counters. `GCRY_HEAP_COUNTERS_ATOMIC=0/1` pins an arm and survives the
flip, which is what makes the two-directional gate possible at all.

Not measured here: Kemal throughput, because this host has no `wrk`. The unit
that matters for a per-allocation change is the per-allocation cost, and that is
the table above; a service benchmark would add scheduler and socket noise to a
0.7 ns question.
