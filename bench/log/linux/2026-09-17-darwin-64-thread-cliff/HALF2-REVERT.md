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
