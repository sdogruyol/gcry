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

## Where the pointer is not

The grace's own result opened a narrower question — *what* holds the newborn
`Fiber`, since something must — and the instrument now asks it while the world
is still stopped. Three answers, all measured on runs that still produced 65–72
saves each:

| question | measured |
|---|---|
| Is it on a fiber stack, above the collector's entry SP? | **no** — 75 of 76 report no live mutator frame holds it |
| Is it in a suspended thread's captured GP registers? | **no** — 0 hits across 92 registers of 4 captured threads (of 6), 85 of 85 reports |
| Would the mark take it if a scan handed it over? | **yes** — `mark_root_candidate` ACCEPTS the address, 88 of 88 |

The third is the one that matters: **no root predicate rejects the value.** It is
not the type_id gate, not `base_only`, not alignment, not the minor filter. The
address is acceptable and simply never arrives. That makes this a **scan-coverage
gap**, not a filter — and it rules out the whole class of fixes that would have
been about loosening a heuristic.

What is left unexamined is one region: the collector's own frames on the
collecting thread, where a value the mutator held in a callee-saved register is
spilled by the collector's prologues. `scan_mutator` covers it by design (it
starts from its own SP, below the entry frame), which is why it is the last
place to look and the hardest to look at — see the correction below.

## A correction: the instrument found itself

The first version of the locator walked the current fiber's whole stack and
reported **87 of 87** hits "inside `scan_mutator`'s window — read and rejected".
That was an artifact. `locate_birth_holder(user)` takes the address as a
parameter, so the value is on the stack *because the search is running*, and
every hit landed at the same offset — 1520 bytes above the window's low bound,
i.e. inside the collector's own call chain. Excluding frames below the
collector's entry SP (`Heap#collect_entry_sp`, recorded at the top of
`run_collection`) removed **every** hit.

It is recorded because it would otherwise have become a finding: "the collector
read the slot and refused the value" is a completely different defect from the
one the corrected instrument reports, and nothing about the first reading looked
wrong.

## And a caution: the repro went quiet

Late in the same session, on the same host, the **committed** binary that had
been crashing 6/15 and 10/24 stopped reproducing entirely: 0/8 at the documented
`ROUNDS=200` config and 0/12 at `ROUNDS=20` under four-way parallel load. No code
change is responsible — the same binary, minutes apart. The rate is host-state
dependent.

So the numbers in this file that compare arms — 20/48 against 0/48 — were taken
**back-to-back in the same conditions, twice**, and stand. Any *new* arm has to
wait for the repro to be live again, and a quiet run proves nothing. This is the
board's own standing warning about the soak, arriving at a two-second repro.

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

**Next**: the only region left is the collector's own frames, and the way to
look at it without the search contaminating it is to stop looking at the stack.
Capture the mutator's registers with a `setjmp` taken at collect *entry* —
before any collector frame exists — and search that buffer for the address. If
the value is there, the gap is that `scan_mutator`'s spill happens after frames
that can clobber it; if it is not, the value is somewhere gcry has never
looked, and that is a different and larger finding.

## Status of the knob

`GCRY_BIRTH_GRACE=1` is **research only** and off by default. It is not a fix:
it keeps every allocation alive for a whole collection, which is a retention
policy nobody chose, and shipping it would hide the defect rather than close it.
It stays because it reports *what* it saved, and that is the instrument the next
round needs. `birth_grace_rooted` / `birth_grace_saved` /
`birth_grace_overflows` are on `/gc-stats`.
