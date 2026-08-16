# The fiber-creation use-after-free: who still points at the freed block

2026-08-16, x86_64 WSL2, Crystal 1.21.0, `bench/nested_spawn_uaf.cr`.

`bench/log/linux/2026-08-15-nested-spawn-uaf/FINDINGS.md` got as far as naming
the block — 384 / 768 / 1536 / 3072 bytes, always `still FREE` — and stopped at
"gcry freed it correctly; something still reads it". Two interventions took the
crash to zero and a bounded grace on `Heap#realloc`'s root did not, so the stale
pointer is held **indefinitely**, by something nothing had named.

`GCRY_POISON_HOLDERS=1` names it, and then names what points at *that*
(`src/gcry/poison_holders.cr`, gated by `make poison-holders`).

## The chain, and it is the live pool

Two rounds, 18 runs, 7 crashes, and the answer does not vary:

```
live ec pool 0x7632398e3df8 deque 0x7632398e3dc8
gcry: the free that wrote it was of the block at 0x7632394deeb8, still FREE, size 3072, flags 0x1
gcry: holders — explicit roots: 0 of 0 point into it — gcry is not rooting it
gcry: holders — heap: block 0x7632398e3dc8 size 32 type_id 210 flags 0x0 holds it at +16 (block+0)
gcry:   payload +0=0xd2 +8=0x8000000040 +16=0x7632394deeb8 +24=0x0
gcry: holders — stack: fiber 0x… (running) slot 0x… holds block+0, stack_top 0x…
gcry: owner — and who points at that holder? [0x7632398e3dc8, 0x7632398e3de8)
gcry: owner — explicit roots: 0 of 0 point into it — gcry is not rooting it
gcry: owner — heap: block 0x7632398e3df8 size 32 type_id 199 flags 0x20 holds it at +16 (block+0)
gcry:   payload +0=0xc7 +8=0x101 +16=0x7632398e3dc8 +24=0x0
gcry: owner — stacks: 0 word(s) across 12 stack(s)
```

Read against the addresses the harness prints **before anything goes wrong**:

| | address | what it is |
|---|---|---|
| freed block | `0x7632394deeb8` | 3072 bytes |
| its only heap holder | `0x7632398e3dc8` | **= `live ec pool deque`** — `type_id` 210 = `Deque(Fiber::Stack)` |
| that holder's only holder | `0x7632398e3df8` | **= `live ec pool`** — `type_id` 199 = `Fiber::StackPool` |

Not an abandoned buffer, not an orphaned deque: it is the execution context's
**own** stack pool and its **own** deque, matched by address, every time.

**And the deque's state is coherent, so it is not caught mid-resize.** `Deque`'s
object is `type_id`, three `Int32`, then `@buffer` at +16, and the dump decodes:

| run | freed block | entries (÷24) | `@capacity` (+12) | `@size` (+8) |
|---|---|---|---|---|
| r2 | 1536 B | 64 | **64** (`0x40`) | 32 |
| r3 | 3072 B | 128 | **128** (`0x80`) | 64 |
| r5 | 3072 B | 128 | **128** (`0x80`) | 66 |

`@capacity` matches the freed block's entry count exactly, and `@size` is below
it. `Deque#resize_to_capacity` writes `@capacity` **before** `@buffer`, so a
resize caught between the two would show a capacity larger than the block
`@buffer` still points at. It does not. This deque is not mid-resize — it holds
the buffer it believes is its current one, and gcry freed that buffer.

That is a stronger claim than the 2026-08-15 cut's, and it contradicts part of
it: "the block is a buffer the deque **abandoned** at a resize" does not survive
this measurement. The freed block is sized to the deque's live `@capacity`.

## A correction to this file's own first cut

The first version of this instrument printed `UNMARKED` whenever a block's mark
generation was zero, and this file read that as "no collection ever marked the
holder", concluding that the buffer was freed *because its owner was not marked*.
**That was wrong.** `sweep` calls `heap_clear_mark` on every survivor
(`src/gcry/collect_sweep.cr:127`, `:146`, `:347`), so between collections **every
live object in the heap has zero mark-generation bits**. Measured rather than
argued: an object held in a local across three collections reads `flags 0x0`,
exactly like the holder.

The verdict is gone from the reporter. Raw flags are still printed, because the
other bits do mean something outside a collection — `ATOMIC` (0x2) says the
collector never scans that block's payload, and it is now called out by name.
The `Fiber::StackPool` block's `0x20` is `FINALIZER`, which is expected:
`StackPool#finalize` frees the pooled stacks.

## What is eliminated

- **Not gcry rooting it wrongly.** `explicit roots: 0 of 0` at fault time, at
  both levels, in every crash. `Heap#realloc`'s `add_root`/`delete_root` pair is
  balanced.
- **Not a stack-scan window hole.** Every stack holder sits on a **running**
  fiber at an address *above* `stack_top` — inside the window the collector
  scans, not below it.
- **Not an unscanned holder.** Neither the deque nor the pool is `ATOMIC`; both
  are ordinary scanned blocks.
- **Not a mid-resize race in `Deque`.** See the capacity table above.
- **Not an orphaned or duplicate pool.** Both levels match the live context's
  pool by address.

## What it leaves, and it is now a single question

The pool is an ivar of the execution context — Crystal 1.21.0 declares
`getter stack_pool : Fiber::StackPool = Fiber::StackPool.new` on
`Fiber::ExecutionContext::Parallel` — and gcry pins every pointer-bearing ivar of
every EC type by name, derived from `instance_vars` (`pin_ec_ivars`). The context
itself is also a local in `__crystal_main`, so the main thread's stack holds it.
So the mark should reach `ec` → `@stack_pool` → `@deque` → `@buffer`, and one of
those four edges does not hold.

`@buffer` is the edge worth suspecting first: it is a raw
`Pointer(Fiber::Stack)`, i.e. exactly the "raw Pointer buffer" shape
`Heap#realloc`'s own comment says the process-GC `type_id_gate` rejects as an
ambient stack root. Whether that gate also filters a heap-to-heap edge out of a
scanned `Deque` payload is the next measurement, and it is a small one: mark a
`Deque(Fiber::Stack)` by hand and ask whether its buffer survives a collection.

## The gate

`make poison-holders`, unchanged by this round: a planted heap holder must be
named by address, a stack-only holder found on the stack, a block nobody holds
must report **0**, and `--control` must print no holder line at all. Both
directions were broken on purpose and observed red when it was written.

Linux only, alongside `make segv-report` and `make poison-freed` —
`SegvReport`'s register scan for the poison is `{% if flag?(:linux) %}`, so on
Darwin the search would have no block address to look for.
