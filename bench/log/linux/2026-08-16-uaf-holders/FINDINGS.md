# The fiber-creation use-after-free: who still points at the freed block

2026-08-16, x86_64 WSL2, Crystal 1.21.0, `bench/nested_spawn_uaf.cr`.

`bench/log/linux/2026-08-15-nested-spawn-uaf/FINDINGS.md` got as far as naming
the block — a `Deque(Fiber::Stack)` buffer abandoned at a resize, 384 / 768 /
1536 / 3072 bytes, always `still FREE` — and stopped at "gcry freed it
correctly; something still reads it". Two interventions took the crash to zero
and a bounded grace on `Heap#realloc`'s root did not, so the stale pointer is
held **indefinitely**, by something nothing had named.

`GCRY_POISON_HOLDERS=1` names it. At fault time the reporter searches the three
places gcry can walk for the freed block's address: the explicit root set, every
live block in the heap, and every fiber stack
(`src/gcry/poison_holders.cr`, gated by `make poison-holders`).

## What it says

Two batches, 37 runs, 17 crashes, and the answer does not vary:

```
gcry: the free that wrote it was of the block at 0x7a9c43a2e758, still FREE, size 1536, flags 0x1
gcry: holders — looking for words pointing into [0x7a9c43a2e758, 0x7a9c43a2ed58), the block whose free wrote the poison
gcry: holders — explicit roots: 0 of 0 point into it — gcry is not rooting it
gcry: holders — heap: block 0x7a9c43e3cdc8 size 32 type_id 210 flags 0x0 UNMARKED holds it at +16 (block+0)
gcry: holders — heap: 1 word(s) in 1 live block(s), from 15763 block(s) in 15 chunk(s). current mark gen 17, collections 16
gcry: holders — stack: fiber 0x7a9c43b7fe68 (running) slot 0x7ffecc3cef08 holds block+0, stack_top 0x7ffecc3cee64
gcry: holders — stacks: 1 word(s) across 12 stack(s)
```

| fact | across 17 crashes |
|---|---|
| heap holders | **1 word in 1 block, every time** |
| that block | **32 bytes, `type_id` 210, pointer at +16, value = block+0**, every time |
| its flags | **0x0 — UNMARKED**, every time |
| explicit roots pointing into it | **0 of 0**, every time |
| stack holders | 1 word (13 crashes) or 4 (1), always on a **running** fiber, never below `stack_top` |
| freed block size | 1536 (11), 3072 (4), 768 (2) |

**`type_id` 210 is `Deque(Fiber::Stack)`.** Printed from the same binary
(`PRINT_TYPE_IDS=1 bin/nested_spawn_uaf`), which is the only way to read a
Crystal type id — they are assigned per program and a signal handler has no
table. `instance_sizeof` is 24, so the object lands in the 32-byte class, and
`Deque`'s ivars are `@size`, `@capacity`, `@start` (three `Int32`) then
`@buffer` — **at byte 16**, which is the offset the report names.

So the holder is a `Deque(Fiber::Stack)` **object** whose `@buffer` still points
at the base of the block gcry freed and poisoned.

## The part that is new, and that changes the reading

**The holder object is UNMARKED, and `flags` is 0x0 — not merely a stale
generation.** `clear_all_marks` bumps the mark generation at the *start* of each
collection, so the gen bits distinguish three states that all print as
"unmarked":

- gen bits == the current generation → marked by the last mark phase;
- gen bits non-zero but older → garbage the sweep has not reached;
- gen bits **zero** → never marked since the last full clear.

The report carries the current generation next to the flags precisely so this is
readable, and it measured **gen 17 / 33 / 201 against flags 0x0**. Generations
wrap at 255 and these are nowhere near a wrap, so this is the third state: the
holding `Deque` object **has not been marked by any recent collection**.

That is not the pool's deque. The earlier findings checked `Fiber::StackPool`'s
live `@buffer` after every collect — **0 dead in 4 800 checks** — and that still
holds. This is a *second* `Deque(Fiber::Stack)` object, one the collector did
not mark, holding `@buffer` into a block the collector therefore had every right
to free.

And the free follows from it directly: if the collector never marked the Deque
object, it never scanned the Deque's payload, so `@buffer` was never a root, so
the buffer was garbage. The buffer was freed **because** its owner was not
marked — the abandoned-buffer story was one level too low.

## What this rules out, and what it does not

- **Not gcry rooting it wrongly.** `explicit roots: 0 of 0` at fault time, in
  every crash: `Heap#realloc`'s `add_root`/`delete_root` pair is balanced and the
  root set is empty. The two interventions that fixed the crash worked by keeping
  the *buffer* alive, not by fixing this.
- **Not a stack-scan window hole.** Every stack holder sits on a **running**
  fiber, at an address **above** `stack_top` — inside the window the collector
  scans, not below it. The report says so per holder, because that was the
  candidate worth eliminating first.
- **Not an uncleared reissued block wearing a dead Deque's image.** Poisoning is
  on in these runs, so any block that has been through a free carries
  `0xdeadf2ee…`, not a plausible object image.

**Still open, and this is the next question:** why is a live `Deque(Fiber::Stack)`
not marked? Either it is genuinely unreachable at mark time and becomes reachable
afterwards (a publication the collector cannot see — which would make this
Crystal's, and `Fiber::StackPool` reading `@deque.empty?` and `lazy_size` outside
its lock is the standing candidate), or it is reachable and the mark missed it,
which is gcry's. The instrument to tell them apart is the same one: walk the
heap for words pointing at the *holder* rather than at the buffer, one level up.

## The gate

`make poison-holders`. Three arms plus a control, each a child process that
faults on purpose:

| arm | asserts |
|---|---|
| `heap-holder` | a planted holder is named **by address**, at the offset it was planted at |
| `stack-holder` | a holder that exists only on the stack is found there |
| `no-heap-holder` | with nothing planted the heap section reports **0** — the arm that fails if the walk matches the freed block on itself or walks FREE blocks |
| `--control` | with the knob off, no holder line appears at all |

Both directions broken on purpose and observed red:

| break | result |
|---|---|
| `search_heap` returns without walking | `heap-holder` NOT named, `no-heap-holder` red |
| `search_stacks` returns without walking | `stack-holder` NOT named |

Linux only, alongside `make segv-report` and `make poison-freed`. The Darwin job
runs none of the three: `SegvReport`'s register scan for the poison is
`{% if flag?(:linux) %}`, so on Darwin the search has no block address to look
for. Adding the gate there before that path exists would be a gate measuring
nothing — the same defect the Darwin RSS reader had.

## Cost

None until something faults. The search runs from the SIGSEGV handler, after the
process is already dead; the walk of ~16 000 blocks in 15 chunks is not timed
because nothing downstream of it is waiting.
