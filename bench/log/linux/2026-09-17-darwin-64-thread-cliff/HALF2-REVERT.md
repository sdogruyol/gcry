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


## Second attempt, 2026-09-18: also reverted, and it moved the question

The re-land put the table in one shared module — `src/gcry/stw_slots.cr`, used
by both platforms — and added `spec/stw_slots_spec.cr`, eight examples that run
wherever the suite does. That part worked, and it did what the first attempt
could not:

**The first attempt's crash now reproduces on this host in under two seconds.**
Four threads walk the table (`sp` and `each_greg` over 128 ids) while the main
thread doubles it twelve times. Shipped design — one `LibC.malloc` block
published by a single pointer store, never freed — **8 of 8 green, three runs**.
Restore the reverted design, freeing the predecessor at the publish, and it
faults **3 of 3** with libc backtraces through the reader. So that crash was
never Darwin-specific: it was a use-after-free only Darwin's job executed.

**And Darwin failed anyway — the same step, deterministically.**
`make chunk-search-race` died with `Process terminated because of an invalid
memory access` after all nine of its arms printed their own `ok`, on the run and
on a rerun of the same commit. The unit suite on that job, including the eight
new examples, passed.

**What that rules out.** The harness is built **without** `-Dgc_none`:

    crystal build bench/chunk_search_race.cr -o bin/chunk_search_race

`install_stw_sp_capture` is called only from `gc_override.cr`, which is required
only under that flag, and every entry point into the table — `slot_for`,
`clear_thread_sps`, `thread_sp`, `each_thread_greg` — returns early unless
`@@stw_booted`. Its probes fake the stopped world (`@world_stopped = true`)
instead of suspending anyone, so `stop_world_threads` is never reached either.
**The changed code cannot execute in that binary**, and the crash is still
deterministic on it and absent on the commit before.

That leaves an indirect mechanism, and the honest answer is that this host cannot
see it. Two candidates worth instrumenting rather than arguing about: the ~17 KiB
of static arrays the change removes from `Gcry::Platform`, which moves the
writable segment this platform scans as conservative static roots and which is
documented to shift chunk residency elsewhere in this tree
(`segv_report.cr`'s 256 KiB report-buffer note); and a latent fault in that
harness's own teardown, which the layout change makes reachable.

**So the code is out again and the next step is not a third blind attempt.** It
is a report: that harness is a library build, so gcry installs no SIGSEGV
handler in it, which is why two runs of a deterministic fault produced one line
and no address, no backtrace and no release ledger. Making it say what it faults
on is the prerequisite for the third attempt, and it is worth having whether or
not the table ever grows.


## Third round: the crash is bisected, on a branch, with master green

Master carries neither attempt. The hunt moved to `half2-darwin-probe`, which
CI runs in full because the workflow has no branch filter — so Darwin answers
without the tree going red.

Four rounds, each one question:

| probe | Darwin |
|---|---|
| the re-land, with the report installed only in the child arms | **red**, one line |
| report installed in the parent too, plus `all arms returned` / `exiting 0` markers | **red**, and the markers moved the question |
| ~17 KiB BSS pad in `Gcry::Platform`, restoring what the change removed | **red** — layout refuted |
| `stw_slots.cr` and its spec present, platform files back at master's | **green** |

What that establishes:

- **The parent crashes, and it crashes after `exit 0`.** Its last two lines are
  `parent: all arms returned` and `parent: exiting 0`; all nine children print
  their own `ok`, and the parent prints no `FAIL` line, so nothing in the loop
  failed. The fault is in the parent's own exit.
- **It is not the ~17 KiB of static arrays** the change removes from
  `Gcry::Platform`. A pad of the same size in the same module, kept alive by a
  touch from the harness, changed nothing.
- **It is not the shared table.** With `stw_slots.cr` compiled in and the
  platform files restored, the job is green — so the module, its spec and the
  requires are innocent, and the trigger is the **Darwin STW wiring**.
- **No `gcry:` report line appears**, even with the handler installed in the
  parent. The most likely reading is a fault on a thread that never got an
  alternate stack: the report needs ~4.7 KiB and `install_alt_stack` is
  per-thread, so on a pool thread it would smash what it is trying to describe.
  That is a reading, not a measurement.

Next round, already pushed: `darwin_stw.cr` back at the re-land's version and the
parent calling `LibC._exit(0)` after flushing. Green means the fault is in
Crystal's exit path; red means it is before it. Either way the answer is one bit
and the tree stays green while it arrives.
