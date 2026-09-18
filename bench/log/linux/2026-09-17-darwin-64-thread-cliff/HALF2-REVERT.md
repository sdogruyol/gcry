# Half 2 went in, crashed Darwin, and came back out

## What happened

`29b74f0` made the STW capture table growable on Darwin and Windows. CI:

- **Darwin: `Process terminated because of an invalid memory access`** in
  `make chunk-search-race`, after all nine of its arms had printed their own
  `ok`. The step had been green on the commit before.
- Linux and aarch64 failed too, but for reasons unrelated to that change (a
  cost precondition and the spec-helper wait; both fixed separately).

## Why it was reverted rather than patched forward

There is no Darwin host here, so a second attempt would have been another blind
push and another thirty-minute round trip on a red tree. The source change is
out; the measurements it rested on are not, because they were the valuable part.

## What the crash most likely is, for whoever picks this up

The tables became `LibC.malloc`ed and `grow_stw_table` **frees the old ones**.
Static arrays tolerated concurrency that malloc'ed-and-freed ones do not:

- `ensure_stw_table` has no atomicity around `@@stw_booted`, so two threads can
  both boot the table; with static arrays that was idempotent, with `free` the
  loser frees a table the winner is using.
- `Platform.thread_sp` is called from `stack_scrub.cr` and from
  `fiber_stack_sp_scan_low`, and `chunk_search_race` builds **without**
  `-Dgc_none` — library heaps, whose marking does not stop the world. A reader
  there can be inside the table while the collector grows it.
- Publication is not ordered: `@@stw_capacity` and the array pointers are
  separate stores, so a reader on aarch64 can pair a new capacity with an old
  pointer and run off the end.

A re-land should therefore: **never free** (leak the predecessor; growth doubles,
so the leak is bounded by the final size), publish capacity *after* the pointers
with a release/acquire pair — `Atomic::Ops.fence` is already used in this tree —
or better, put capacity and arrays in **one** allocation published by a single
pointer store, and snapshot that pointer once per reader instead of re-reading
the capacity every loop iteration.

## What survives

The measurements, which are unaffected by the revert and are in `FINDINGS.md`:

- a missing SP clamp is conservative (`scan_pthread_stack` with a nil SP walks
  the whole stack);
- Linux's registers are in a `ucontext` on the interrupted thread's own stack —
  the handler carries no `SA_ONSTACK` — so its no-slot case costs precision, not
  roots. Only Darwin loses a root, and Windows loses the whole collection by
  refusing the stop;
- `stw_capture_no_slot` is arithmetic once explicit collects land: zero at 65
  threads on the list, `2 x (needing_a_slot - 64)` past it.


## Re-landed 2026-09-18, and this time the crash is reproducible here

The lesson of the revert was not about pointers, it was about **where the code
lived**: a table reachable only from Darwin and Windows cannot be debugged on a
host that runs neither. So the table moved to `src/gcry/stw_slots.cr`, one
implementation shared by both platforms, and `spec/stw_slots_spec.cr` covers it
wherever the suite runs — eight examples: initial capacity, distinct slots, the
65th thread being turned away and counted, coverage past the initial capacity
after a reserve, SP and register round-trips across a grow, an unfilled slot
yielding nothing, `clear` forgetting a collection, the pin knob, and the one
that matters.

**The one that matters, and it comes out red.** Four threads walk the table
(`sp` and `each_greg` over 128 ids) while the main thread doubles it twelve
times. Shipped design: 8 of 8 green, three runs. Restore the reverted design —
`LibC.free` the predecessor at the publish — and it faults **3 of 3**, with libc
backtraces through the reader:

    [0x7f42a48acfb1] ?? in /usr/lib/libc.so.6
    [0x0] GC_call_with_stack_base +41 in /usr/lib/libgc.so.1

That is the Darwin crash, on this host, in under two seconds. It was never
Darwin-specific — it was a use-after-free that only Darwin's job happened to
execute.

**The three rules the re-land is built on**, in the module's own words:

1. **One allocation, one pointer.** Capacity and every array live in a single
   `LibC.malloc` block published by a single store, so a reader can never pair a
   new capacity with an old base. The reverted version had capacity and five
   pointers in six separate stores.
2. **Never freed.** Growth leaks its predecessor, so a reader still inside the
   old block reads stale-but-valid memory. Doubling bounds the leak: 64 → 128 →
   256 sums to less than 512 slots' worth.
3. **Grown outside the stop.** Both stop loops size the table from
   `Thread.unsafe_each` plus eight slots of slack *before* suspending anyone.

Also folded in: both stop loops hand the claimed slot index down to the capture
(`capture_thread_state(port, id, slot)` on Darwin, `record_thread_context_at` on
Windows), so the linear `slot_for` runs once per thread per stop instead of
twice; Windows' handle list grows the same way and its refusal at the 64th
thread is gone; ids are keyed as `UInt64`, which is what `pthread_equal`
compares on a platform whose `pthread_t` is an opaque pointer.

**Verified here:** 285 examples (277 + the 8 new) and 32 process specs green,
all four cross-targets type-check, and `greg-roots`, `stw-epoch`, `tls-roots`,
`scheduler-roots`, `dead-stack-root`, `holders-find` and `poison-holders` all
still pass. **Not verified here:** the Darwin and Windows jobs, which are the
first execution of the platform wiring — but no longer of the table's logic.
