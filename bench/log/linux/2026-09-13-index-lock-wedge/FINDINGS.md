# The `@index_lock` wedge: measured, and it needs something this tree does not do

Date: 2026-09-13/14 (overnight) · host: AMD Ryzen AI 9 465, Linux 7.2.4 ·
tree: `39aa4d0` · harness `bench/index_lock_wedge.cr`

`ROADMAP.md` has carried this shape with no reproducer and no number:

> `chunk_containing` holds that spinlock for the length of a lookup, and a
> suspend signal arrives wherever it likes; the sweep's own `index_insert` /
> `index_remove` take the same lock unconditionally, so a thread frozen holding
> it leaves the collector spinning with the world stopped. [...] Left open
> because the fix is not small [...] and because nothing has yet been seen to
> hit it.

Both halves are now measurements rather than readings of the source.

## The precondition does not occur

`index_insert` and `index_remove` count their sections, and whether the world
was stopped when they ran:

| configuration | index-lock sections | of them with the world stopped |
|---|---|---|
| alone (main thread only) | 1 155 | **0** |
| a second mutator holding the lock | 586 | **0** |

None. On this tree the collector's index surgery runs with mutators running —
the sweep's placement is `sweep_after_world?` — so there is no section a frozen
holder can block, and the wedge needs one.

## What a holder costs instead

A mutator holding `@index_lock` for 30 s across a collection does stall the
collector: the child has to be killed at the harness's 12 s deadline. With a
**1.5 s hold the child finishes**, which is the operational difference between
the two — the collector is waiting for a lock whose owner is still *running*,
and that resolves when the owner lets go. A frozen owner would not.

So the cost today is a stall bounded by whatever the holder is doing, and the
deadlock this item describes requires an in-stop section that does not exist.

## And if it ever does

The watchdog could previously say `STALLED ... in phase=sweep` and no more,
which does not name a lock and leaves a reader nowhere to go. `index_insert` and
`index_remove` now leave a breadcrumb — two plain stores around a lock
acquisition — so the report says *which* lock, and which chunk the collector was
in that section for. `make index-lock-wedge` fails if a section ever runs inside
the stop without the watchdog naming it, which is exactly the silent-hang shape.

The item stays open: this is a property of the current sweep placement, not a
proof. Anything that moves index surgery into the stop under multiple mutators
reopens it, and the gate is what notices.
