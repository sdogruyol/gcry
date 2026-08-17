# The value lives on fiber stacks that belong to nobody

2026-08-17. The elimination chain around the dying `Deque(Fiber::Stack)` buffer
was complete and self-contradictory: at the moment the sweep frees it, the
block's address is in no used heap block, in no suspended thread's registers, in
no explicit root — and the crash report finds it on a stack immediately
afterwards. Every place gcry looks says the value is not there.

So this round stopped asking gcry and asked the kernel. `GCRY_ADDRESS_SPACE_AUDIT=1`
(`src/gcry/address_space_audit.cr`) walks every readable mapping in
`/proc/self/maps` at the moment of death, searches it word-aligned for the
dying block's address, and **names the region that holds it**.

## The answer

Fourteen runs at `ROUNDS=20 FIBERS=64`, one audit per collection:

| where the address was found | hits |
|---|---|
| **an in-flight fiber stack** — mapped `STACK_SIZE - PAGE_SIZE`, guard page below, owned by **no fiber** and in **no pool** | 61 |
| **a pooled fiber stack** — sitting in a `Fiber::StackPool` deque | 24 |
| the collecting fiber's own stack, below the window the scan used | 47 |
| the collecting fiber's own stack, inside that window | 6 |
| the libc heap (`[heap]`, i.e. `brk`) | 4 |

The first two rows are the finding, and they are the same thing at two points in
its life. gcry scans the stack of every fiber `Fiber.unsafe_each` yields. A
stack that no fiber owns is yielded by nothing, so it is scanned by nothing —
and the pointer sitting on it is invisible to the mark while remaining perfectly
alive to the program.

Both kinds of hit land in the same place: **968 to 1408 bytes below the stack
top**, which is where `makecontext` writes a new fiber's initial frame. That is
not a coincidence of layout, it is the frame itself.

## Two windows, one shape

- **In flight.** `Fiber.new` calls `stack_pool.checkout`, which `shift?`s the
  stack out of the pool's deque, and only later publishes the `Fiber`. Between
  those two points the stack is held in a local of the *creating* fiber and
  belongs to no `Fiber` object. A collection in that window scans neither it nor
  what `makecontext` has already written onto it.
- **Pooled.** After a fiber finishes, its stack goes back into the deque with
  its last frames intact. gcry scans nothing there either.

## What the instrument had to be corrected for, twice

Both corrections are the reason the numbers above are worth anything.

- **It read itself.** The first version dereferenced memory directly and
  reported the target "held on a running fiber's stack, inside the scan window".
  Forty-seven of those hits are `audit_address_space`'s own frames: the audit
  runs on the collecting fiber's stack and carries the target as an argument.
  The classifier now compares against `Roots.last_mutator_low/high` — the window
  the scan *actually* used, recorded at scan time — and calls everything below
  it what it is.
- **It took a SIGBUS.** A mapping `/proc/self/maps` calls readable can still
  fault. The first run died at 0x…567000 inside the audit, killing the
  collection it was measuring. Reads now go through `pread` on `/proc/self/mem`,
  which reports the same page as an error; a bad page costs one page.

The negative answers are counted too, because "no pooled stack" from a walk that
found no pools is not an answer: the summary line prints how many fibers, pooled
stacks and thread bounds the classifier compared against.

One narrower correction: the geometry test first required the guard page to sit
on a `STACK_SIZE` boundary and missed six hits in a run — `allocate_stack`
mmaps, and mmap promises page alignment, not stack-size alignment. Size alone.

## What this does not yet say

- **None of these runs crashed.** The repro needs `GCRY_POISON_FREED=1` to
  fault, and the audit runs were made without it, so every report above is of a
  block the sweep freed in a run that then finished cleanly. The blocks are the
  right sizes and the holders are where the crash reports have always pointed,
  but "this is the block the crash dies on" is inference from shape, not an
  observation at a fault. Turning both on at once is the next measurement's job.

- **Whether the words are live.** On an in-flight stack, at the offset
  `makecontext` writes, they are; on a pooled stack the fiber that wrote them is
  finished, so those may be stale copies of the same pointer. The counts do not
  separate the two, and the fix has to.
- **Why the libc heap holds it** at all (4 hits). Nothing Crystal allocates
  lives there; a stale word in a reused `malloc` chunk is the likely reading and
  it has not been checked.
- The audit is **truncated at 512 MiB** in the later collections of a run, so
  the hit counts are lower bounds, not totals.

## Reproducing

```
crystal build -Dgc_none bench/nested_spawn_uaf.cr -o bin/nested_spawn_uaf
ROUNDS=20 FIBERS=64 GCRY_THREAD_CENSUS=1 GCRY_ADDRESS_SPACE_AUDIT=1 \
  GCRY_SEGV_REPORT=1 ./bin/nested_spawn_uaf
```

`GCRY_ADDRESS_SPACE_AUDIT=1` implies `GCRY_DYING_REGISTER_AUDIT=1`: it is that
audit's "dies unreferenced" branch that asks the question. One audit per
collection, because the walk is O(resident memory) inside the pause.
