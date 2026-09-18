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


## Fifth round: not the exit path either

`darwin_stw.cr` back at the re-land's version, parent calling `LibC._exit(0)`
after flushing both streams. **Still red**, and the log is the same two markers
followed by the fault:

    parent: all arms returned
    parent: exiting 0
    Process terminated because of an invalid memory access

`_exit` does not run `at_exit`, and if it had executed the process would have
died with status 0 and printed nothing further. So the fault arrives **before**
`_exit` runs — between the last flush and the syscall — which rules out
Crystal's teardown as well.

What that leaves, and it is consistent with every round so far: a **fault on a
thread other than the main one**, around the moment the parent finishes. The
parent has scheduler/event-loop threads (`BoundedChild` sleeps between polls),
the message is Crystal's handler rather than gcry's, and gcry's report needs an
alternate stack that only the installing thread has — so a fault on a pool
thread would print exactly this: one line, no address.

## Where this is parked

Master carries neither attempt and is green. The branch `half2-darwin-probe`
holds the instrumented harness and the re-land's `darwin_stw.cr`, and the next
split is inside that one file, one bit per round:

1. growable table but the old `capture_thread_state(port, id)` signature — does
   handing the slot index down matter?
2. growable table but `ensure_stw_table` not calling `StwSlots.configure`, so
   the table never allocates — does the `LibC.malloc` at boot matter?
3. the old static tables with only `stop_world_threads`' pre-suspend
   `Thread.unsafe_each` count added — does *that* walk matter?

(3) is the one I would try first: it is the only thing the re-land added that
runs on a path a library build can reach, and walking Crystal's thread list from
a process that is shutting down is exactly the shape a fault on a pool thread
would take.


## Found: a class variable with an initializer, read inside `GC.init`

2026-09-18, after eight probe rounds on a branch. The whole hunt turned on
reading one line properly.

**The message was never the crashing process's.** `Process terminated because of
an invalid memory access` is `Process::Status#description`, and the only thing
that prints it is `crystal` itself —
`compiler/crystal/command.cr:356`, `STDERR.puts status.description`, when a
program it *ran* dies abnormally. So it was not `chunk_search_race`'s parent
dying at exit, which is what four rounds of markers and `_exit` had me
believing: the step's *next* command is `crystal spec -Dgc_none process_spec`,
and that binary was dying **at startup, before printing anything**. Every
earlier attribution in this file is retracted, and this is why `_exit(0)`,
a 16 KiB pad and restored statics all stayed red — none of them touched the
thing that was broken.

**The defect.** `Gcry::StwSlots` declared its class variables with
initializers:

    @@table = Pointer(UInt8).null
    @@greg_words = 0
    @@no_slot = 0_u64
    @@pinned = false

A class variable with an initializer is set up **lazily behind `Crystal.once`**,
and Darwin's `install_stw_sp_capture` boots the table from `GC.init` — before
`Crystal.main` has set that machinery up. So the first `-Dgc_none` binary on that
platform faulted immediately. `linux_stw.cr` carries this exact rule in a
comment, for this exact reason, and I did not follow it:

> `uninitialized`, and defaulted in `ensure_stw_table`, for the reason the rest
> of this table is: a class variable with an initializer is set up lazily behind
> `Crystal.once`, and the **first** read of this one is inside the suspend
> handler.

**The fix** is the pattern the platform files already use: `uninitialized`
declarations, a plain `@@booted = false` literal as the gate, defaults assigned
in `configure`, and every reader gated on it. Darwin green with the full wiring
on the next round.

## The eight rounds, for whoever reads this next

| probe | Darwin | what it said |
|---|---|---|
| re-land, report in the child arms only | red | one line, nothing else |
| report in the parent + `all arms returned` / `exiting 0` markers | red | *looked* like the parent dying at exit — wrong |
| 16 KiB BSS pad in `Gcry::Platform` | red | layout refuted |
| module present, platform files at master's | green | the module and its spec are innocent |
| re-land + legacy statics restored | red | read as "follows the code" — too strong, the layout changed again |
| re-land + parent `LibC._exit(0)` | red | not Crystal's teardown |
| master + 16 KiB statics, no Half 2 code | **green** | "any perturbation" refuted |
| master + `StwSlots` present and touched | **green** | presence and lazy init of the module alone are fine |
| `uninitialized` + `@@booted` gate | **green** | the once-guard was the defect |

Two lessons worth more than the fix. **Read the message's provenance before
reasoning from its content** — four rounds were spent on a process that was not
crashing. And **a rule the tree already documents is a rule to follow**: the
comment in `linux_stw.cr` describes this failure precisely, three files away from
where I reintroduced it.


## Then Windows: the spec that starved the runner

2026-09-18, master `e032438`. Every job green except the six Windows ones, which
came out **cancelled** — twice, on a push run and a dispatch run. Cancelled, not
failed, is an infrastructure shape, so I read one job instead of guessing:

    15:15:52  job started
    15:16:16  Windows library specs (default)
    ...       nothing at all for twenty minutes
    15:36:10  Cleaning up orphan processes
    15:36:11  Terminate orphan process: pid (8008) (crystal-run-spec.tmp)

The job's `timeout-minutes: 20` expired while the **library spec binary** was
still running. So the new file in that suite is the suspect:
`spec/stw_slots_spec.cr`'s "survives readers walking the table while it grows",
four threads reading 128 slots flat out while the main thread doubles the table
twelve times. On this 20-core host that example is 170 ms. On a two-vCPU Windows
runner four spinning readers and a main thread that has to be scheduled between
`Thread.sleep(2.milliseconds)` steps is a different machine entirely.

**The obvious fix made the example worthless, and that is measurable.** Two
readers, a 200 µs sleep per pass, six doublings and a deadline — then the
red arm: `LibC.free` the predecessor on growth, which is the bug the design
exists to avoid.

| spec variant | freeing the predecessor |
|---|---|
| 4 readers flat out, 12 doublings (original) | faults 3/3 |
| 2 readers with 200 µs sleeps, 6 doublings | **passes 5/5** |

A gentle race gate is a survival assertion. The first variant works because at
twelve doublings the block is ~13 MB, which the allocator unmaps instead of
recycling, and because a flat-out reader is nearly always inside it — take away
either and freeing the old table is invisible.

**So it moved instead of shrinking**: `bench/stw_slots_grow_race.cr`, run by
`make stw-slots-grow-race` in the Linux job, two arms as bounded children —

    hold 1/3: ok child: grown=12 capacity=262144 reader_passes=158
    hold 2/3: ok child: grown=12 capacity=262144 reader_passes=155
    hold 3/3: ok child: grown=12 capacity=262144 reader_passes=158
    free 1/3: died
    free 2/3: died
    free 3/3: died

with `GCRY_STW_SLOTS_FREE_OLD=1` as the arm that must kill its children, and the
gate failing if fewer than 2 of 3 die. 3.3 s total. `spec/stw_slots_spec.cr`
keeps the seven deterministic examples, all of which pass with the bug present —
which is the point: they cover shape, and the gate covers the property.

The lesson is about where a test lives. A race that has to starve a machine to
be visible does not belong in a suite that every platform runs on whatever
runner it was given; it belongs in a gate with a deadline and a red arm.


## And then the spec reconfigured the collector's table

Moving the race out did not fix Windows: run `35369782659`, all six jobs
cancelled again at the 20-minute cap, with the library spec suite stuck at
**218 of 270 examples**. (The `Entering debug mode. Use h or ? for help.` and
`At ci\windows.ps1:37` in that log are the runner's cancellation breaking into
the PowerShell debugger, not a cause — worth knowing before it costs another
round.)

The green run two hours earlier says how much headroom there was: the same step,
**16 seconds**, 270 examples. It also carries the same
`GCRY INVARIANT FAILURE: live_objects mismatch: actual=1 reported=2` line, so
that message is expected output from an example and not a regression — checking
it against a green run cost one API call and would otherwise have been the next
wrong lead.

**What was left in the file was worse than the race.** `spec/stw_slots_spec.cr`
reconfigured the *process-wide* table:

    around_each do |example|
      saved_words = 8          # invented, not read from anywhere
      Gcry::StwSlots.reset_for_test
      ...

On Linux that mutates dead state — this platform keeps its own fixed table. On
Windows it is the table the collector reads inside the stopped world. Measured
on this host with the platform's own width:

| step | register words the scan can see |
|---|---|
| collector configures its table (`GREG_WORDS = 80`) | 80 / 80 |
| a spec example runs `configure(4)` | **4 / 80** — 76 register roots dropped per thread |

and the "turns a thread away once the table is full" example fills all 64 slots
with fake ids, so the next real thread's claim lands on `no_slot` and is
suspended with no SP clamp and no registers at all. A spec suite that runs 270
examples under gcry, with 76 of every thread's 80 register words dropped, is
collecting live objects out from under itself.

First guess was a buffer overflow — `record_gregs` writing an 80-word row into a
slot sized for 4 — and it was wrong: that method clamps to the configured width.
It is root loss, not corruption of the table.

**The fix is a value type.** `Gcry::StwSlots::Table` is a struct holding the
scalars and the one `malloc`ed block; the collector owns one in `@@process`
(still `uninitialized` + a plain `Bool` gate, for the `Crystal.once` reason
above) and every spec and gate builds its own on the stack. `reset_for_test` is
gone, and a new example asserts the isolation directly: a capture recorded into a
test's table must not be visible through `Gcry::StwSlots`.

Three rounds, three different mistakes, one shape: **a test that reaches into
live collector state is not a test of it.** `crystal spec` runs every file on
every platform, so any module a spec configures has to be one a spec can own.


## Third time, same rule: `Crystal.once` inside the stopped world

The value-type refactor did not fix Windows either — run `35373643054`, all six
jobs cancelled at the cap again, the suite stuck at the *same* place (217–218
examples in the `default` variant, 238–239 in `headers` and `freelist`, which
run a different number of examples before it). Same example every time, so not a
race: something deterministic, and reached only once a spec collects with other
threads running. The local ordering puts that region at the multithreaded
collection specs (`Gcry MT alloc storm (TLAB)`,
`counters while lazy sweep runs beside mutators`).

Reading the whole diff of the one platform file against the last green revision
found it in the declarations, again:

```
-  @@stw_handles = uninitialized StaticArray(LibC::HANDLE, MAX_STW_SP_SLOTS)
+  @@stw_handles = Pointer(LibC::HANDLE).null
```

`Pointer(LibC::HANDLE).null` is a **method call**, so that class variable is set
up lazily behind `Crystal.once` — and `Crystal.once` takes a process-wide mutex.
The first read of `@@stw_handles` is in `resume_suspended_threads`, which runs
**inside the stopped world**. Windows suspends threads asynchronously, so a
suspended thread can be holding the once mutex, and the collector then waits for
a lock that nothing will release: the process hangs with the world stopped,
forever, which is exactly a spec suite that stops printing mid-example and burns
the job's whole budget.

It is the same expression that crashed Darwin at startup two attempts ago
(`@@table = Pointer(UInt8).null`), where the first read is in `GC.init` instead.
The rule was already written in the comments of all three platform files. I
broke it twice.

**So it is mechanical now.** `ci/once-guard.py` (`make once-guard`, and a CI
step) fails when any class variable in `stw_slots.cr` or the three
`*_stw.cr` files is declared with anything but `uninitialized` or a literal.
Observed red on the offender it was written for:

    FAIL: class variables the stopped world reads, declared with a lazy initializer:
      src/gcry/platform/windows_stw.cr:23: @@stw_handles = Pointer(LibC::HANDLE).null

and green after the declaration became `uninitialized LibC::HANDLE*` with its
default assigned in `ensure_stw_table`.

Worth writing down twice: **`uninitialized` in these files is not a style
choice, and a comment saying so was not enough.** The cost of finding this out
by CI was three reverts, a red master for most of a day, and eighteen Windows
jobs that told me nothing except *where* they stopped.


## The actual wedge: a spec that pinned the bound

`--verbose` on the Windows spec run named it in one round. The last example to
finish was `Windows platform > uses distinct thread IDs instead of the
current-thread pseudo handle`; the next one is
`spec/platform_windows_spec.cr:157`:

```crystal
it "resumes threads and releases collector locks when suspension capacity is exceeded" do
  ...
  65.times { workers << Thread.new { ... } }
  expect_raises(Exception, /Windows thread suspension/) { heap.stop_world }
```

That example **asserted the bound Half 2 removes**. With the table growing,
`stop_world` succeeds, so `expect_raises` fails — *with the world stopped* — and
the `ensure` immediately joins 65 threads the collector has suspended. Nothing
resumes them and nothing can print: the process hangs holding the world, which
is a spec suite that stops mid-example and burns the job's whole budget.
Deterministic, identical every run, and reached only in this one file — which is
why the dot count never moved and why Linux and Darwin never saw it.

The once-guard fix committed before this is still right — a lazily-initialized
class variable read inside the stopped world is a live deadlock waiting for a
suspended holder — but it was **not** this failure. Retracted as the cause.

Both halves of the lesson are about where the evidence was:

* The wedge was named by one `--verbose` run costing 25 minutes, after three
  full rounds of reasoning from dot counts. `crystal spec --verbose` on the
  platform that hangs should have been round one.
* A Windows-only spec file is compiled by **no** local check: its body sits
  inside `{% if flag?(:win32) %}`, so `crystal spec` here never sees it. It is
  now cross-compiled by `make windows-typecheck` — along with the three other
  spec files that carry win32 branches — which at least makes a typo in that
  file a local failure rather than a 25-minute one. The semantic pin needed a
  human; the compile gap did not.
