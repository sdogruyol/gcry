# The fiber-creation use-after-free: a newborn `Fiber` is not a root

2026-08-16, x86_64 WSL2, Crystal 1.21.0, `bench/nested_spawn_uaf.cr`,
`ROUNDS=20 FIBERS=64`, n=24 per arm.

`bench/log/linux/2026-08-16-uaf-mark-complete/FINDINGS.md` bounded the defect
from both sides — freed **by the sweep**, with **zero missed heap edges** at that
sweep — and concluded the block must have died in the window between being
handed out and being stored into an object. This round tests that directly, and
then names what dies.

## The window is the defect

`GCRY_BIRTH_GRACE=1` records every pointer `allocate` returns and marks it as an
explicit root in the next collection, then drops it when that collection ends.
It closes that one window and nothing else.

| arm | crashes |
|---|---|
| control | **10/24** |
| `GCRY_BIRTH_GRACE=1` | **0/24** |
| control (repeat) | **10/24** |
| `GCRY_BIRTH_GRACE=1` (repeat) | **0/24** |

20/48 against 0/48, in back-to-back batches. The arm was verified live before it
was believed — `birth_grace_rooted` is 2 774 with **0 overflows** on a 20-round
run, so a null result could not have been the ring silently dropping entries
(the 2026-08-15 grace-list experiment had to rule that out after the fact).

## What it saves: a `Fiber` being constructed

The grace runs **after** `mark_loop`, so a newborn block the mark did not reach
is distinguishable from one it did, and it reports the ones it had to save. Six
runs, 65–73 saves each, and the reported blocks are one thing almost to the
exclusion of everything else:

| block | reports | what it is |
|---|---|---|
| size **192**, first word **0xa8** | **157** | `type_id` 168 = **`Fiber`** (`instance_sizeof` 176 → 192 class) |
| size 80, first word 0xa2 | 6 | `type_id` 162 |
| size 32, first word a pointer | ~6 | raw buffers (no `type_id`) |

```
gcry: birth grace — block 0x…7868 size 192 first word 0xa8 was born this cycle
      and the mark did not reach it — the sweep would have taken it. collection 72
```

So: **a `Fiber` object, in the middle of `Fiber#initialize`, is reachable from no
root gcry scans.** That is the same call the crash dies in
(`Fiber#initialize` → `makecontext`), and it is why the nesting in this repro
matters — `ec.spawn` is issued from *inside another fiber* on a worker thread,
so the only reference to the half-built `Fiber` is a register or a stack slot on
that fiber's stack while the world is stopped around it.

## What this closes, and what it does not

It closes the question the last three rounds were stuck on. The chain
`ec → @stack_pool → @deque → @buffer` was never broken; the mark was never
incomplete. The block that dies is the one **nothing has stored yet**, and the
`Deque` buffer seen in the crash report is downstream of that.

It does **not** name which root source should have covered it. The candidates are
now specific and few, all on the "running fiber on a suspended thread" path:

- `fiber_stack_scan_top` uses the cheap parked `stack_top` clamp for a *running*
  fiber outside multi-mutator STW, so live frames below it are not word-scanned;
- `scan_stack_containing_sp` covers only the stack that holds the captured SP;
- the suspended thread's GP registers are scanned (v0.19.0), but a value spilled
  into a frame the clamp excludes is neither register nor scanned stack.

**Next**: narrow the grace instead of widening the scan — record which *thread*
allocated each saved block, and whether its address is inside the scan window
that thread's fiber got. That turns "some root source missed it" into a named
one, and the fix follows from which.

## Status of the knob

`GCRY_BIRTH_GRACE=1` is **research only** and off by default. It is not a fix:
it keeps every allocation alive for a whole collection, which is a retention
policy nobody chose, and shipping it would hide the defect rather than close it.
It stays because it reports *what* it saved, and that is the instrument the next
round needs. `birth_grace_rooted` / `birth_grace_saved` /
`birth_grace_overflows` are on `/gc-stats`.
