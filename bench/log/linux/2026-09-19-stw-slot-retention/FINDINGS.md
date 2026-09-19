# Past the 64th thread, Linux never collects that thread's garbage again

2026-09-19, this host (20 cores, Linux 7.2.4, Crystal 1.21.0), `-Dgc_none`,
headerless default.

`ROADMAP.md` has said, in three places, that Linux keeps its STW capture table
at a fixed `MAX_STW_SP_SLOTS = 64` deliberately, because a thread with no slot
loses **precision and not roots**: its registers arrive in a signal `ucontext`
that sits on its own stack, and the scan of that stack runs unclamped, so it
still walks them. The stack-bounds gate's own note says what was left open —
"whether a thread past the 64th ever held the only reference to something".

It is the other direction, and it is not small.

## The measurement

A probe with *N* raw threads; each allocates one 96-byte block, keeps only
`addr ^ KEY` (so no conservative scan can find it through the harness), parks,
and the main thread collects. Nothing anywhere holds the blocks, so every one of
them should go.

| threads on list | unreachable blocks | still allocated after 1 collection | after 2 | after 3 |
|---|---|---|---|---|
| 98 | 96 | **34** | 34 | 34 |
| 62 | 60 | 0 | 0 | 0 |

The survivors are indices 62..95 — exactly the blocks allocated by the threads
that came after the 64th entry on Crystal's list (the main thread and the
monitor take the first two). `98 - 64 = 34`. Deterministic: 3 of 3 runs, same
number, same indices.

## The route, narrowed by knob rather than by reading

| arm | still allocated |
|---|---|
| default | 34 |
| `GCRY_STW_PTHREAD_LAG=65536` (clamp the pthread-map path to the top 64 KiB) | 34 |
| `GCRY_DISABLE_GREG_ROOTS=1` (no register roots at all) | 34 |

So it is neither the pthread-mapping scan nor the register scan. It is the
**fiber** window:

    fiber_stack_sp_scan_low(fiber, guard)
      → asks Platform.thread_sp(thread) for the thread whose SP lies in this stack
      → no capture slot ⇒ no SP ⇒ nil
    fiber_stack_scan_top(...)
      → fiber.running? && stw_multi ⇒ return guard

A Crystal thread's main fiber's stack **is** its OS stack, so the window for an
uncovered thread's own stack collapses to `guard` — the whole 8 MiB, dead frames
included. `GC.malloc`'s call chain is deeper than a parked `nanosleep` chain, so
the plaintext pointer it left behind sits *below* the parked SP: a clamped scan
skips it, the guard-page fallback walks it, and the block is a root for as long
as that thread lives.

Two costs, then, and neither is "precision":

* **Retention.** Garbage allocated by every thread past the 64th is never
  reclaimed. The size is that thread's dead-frame history, not one block.
* **Pause time.** Each uncovered thread is an 8 MiB conservative walk inside the
  stopped world, every collection.

The half that was already argued does hold, and is now checked: a block an
uncovered thread *holds* in its own stack survives (96 of 96). The uncovered
thread does not lose roots — it gains them.

## The gate

`make stw-slot-precision`, three arms as bounded children, and it asserts the
**mechanism** rather than the defect:

    covered    56 threads, all garbage: still_allocated must be 0
    uncovered  96 threads, all garbage: still_allocated must equal listed - capacity
    held       96 threads, each holding its block: all must survive

    arm covered:   threads_on_list=58 slot_capacity=64 uncovered=0  still_allocated=0
    arm uncovered: threads_on_list=98 slot_capacity=64 uncovered=34 still_allocated=34 first=62
    arm held:      threads_on_list=98 slot_capacity=64 uncovered=34 still_allocated=96

That correlation is true of the fixed table today and of a grown table tomorrow,
where both numbers are zero, so the gate needs no edit when the table changes —
and it fails if retention ever appears under the cap (the mechanism is not the
table), exceeds the uncovered count (something else retains), or if a held
pointer stops being a root.

## What this changes about the plan

Half 2 grew the Darwin and Windows tables and left Linux's fixed "for a measured
reason". The reason was about soundness and it still stands; what it did not
cover is this. Growing Linux's table needs what the other two did not: the
claims come from the **suspend signal handler** on every thread at once, so the
one-byte-per-slot claim needs a CAS, and the growth has to happen at stop entry
before the first signal — `malloc` in the handler is not an option. The epoch
bookkeeping (`@@stw_served`, `@@stw_acked`) and the diagnostics
(`@@last_stop_ids/sps`) are per-slot too, so they grow with it.

## Method note

The first version of this harness was written over `bench/stack_bounds_growth.cr`
— a tracked file, a different gate for a different table, built on 2026-09-16 —
because the name matched what I was measuring. Restored from `HEAD` with no loss.
`git log --oneline -1 -- <path>` before writing a bench file, every time.
