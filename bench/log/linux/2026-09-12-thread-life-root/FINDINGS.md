# A birth root that never ended, and the death window it was hiding

Date: 2026-09-12 · host: AMD Ryzen AI 9 465, Linux 7.2.4 · tree `1e90246`
`make thread-birth-root --churn`, and a 40-run churn repro. Started as
"close the birth window"; ended somewhere else, which is the interesting part.

## What the measurement said before anything was changed

Probe: 400 rounds of *8 threads created, one collection, 8 joins* — 3 203
short-lived threads against a collecting heap.

```
staged_waits=400  staged_timeouts=398
birth_armed=70 released=6 outstanding=3197 overflows=3133
census_checks=400 gaps=0
```

Two defects, neither previously recorded.

**1. `ThreadBirthRoot` leaked a root per short-lived thread.** A root was
released only when `stop_world`'s walk found its thread on Crystal's list. A
thread that publishes *and exits* between two collections is never on that
list when the walk runs, so its root was never released. Once 64 of those had
piled up the table was full and every further birth took the overflow path,
which roots and — by design — can never release: `overflows` 3 133,
`outstanding` **3 197 of 3 203**. Each pins a `Thread`, its `@func` closure
and its main `Fiber`. Unbounded, on any thread-churning program.

**2. The pre-stop staged wait gave up on 398 of 400 collections**, spending
its whole 2 000-spin budget first.

## The birth window itself is not what it looked like

Reading `Thread#start` settles it (`crystal/system/thread.cr:239`):

```crystal
protected def start
  Thread.threads.push(self)   # first statement
  Thread.current = self
  @current_fiber = @main_fiber = Fiber.new(...)
```

Between `pthread_create` returning and that push, the new thread runs glibc
startup, one ivar store, and nothing else. It allocates nothing and holds one
GC reference — the `Thread` itself, which `ThreadBirthRoot` roots. And once
it *has* pushed, a stop in progress holds `Thread.lock`, so the push blocks
and the thread cannot run through the stopped world.

So the birth window is narrow and already covered. The **death** window is
not.

## The death window

The same `ensure` block:

```crystal
ensure
  Thread.threads.delete(self)   # off the list — gcry can no longer see it
  Fiber.inactive(fiber)
  detach { system_close }       # still dereferencing `self`
end
```

gcry scans a thread's stack only if the thread is on Crystal's list. From the
`delete` to the actual thread exit, the dying thread is invisible: not
suspended, not scanned, and still using objects reachable only from its own
frames.

**It was masked, and by an accident.** `wait_for_staged_threads` spins 2 000
times before giving up, on every stop, and those spins sit between a thread
detaching and the world stopping around it. They were buying the window time
to close.

Removing the mask — dropping a thread's staging record when it dies, which is
obviously the right thing to do — reproduces the defect:

| arm | crashes |
|---|---|
| tree at `1e90246` | 0 of 40 |
| + drop the staging record at death | **7 of 40** |
| + a pure 4 000-`pause` delay in `pthread_detach` instead | 0 of 40 |

The delay arm matters: the trigger is the missing wait, not the added time.

`GCRY_POISON_HOLDERS=1` on a crashing run:

```
SIGSEGV at 0x0 — gcry's freed-block poison is in the faulting context
that block, 0x…830, still FREE, size 16
holders — explicit roots: 0 of 4 … heap: 0 word(s) … stacks: 0 word(s)
holders — none. … the pointer is in a register, in thread-local storage, or
in memory gcry never mapped
```

and the dying-type audit naming `Thread` objects mid-sweep:

```
block … size 192 type_id 171 is unmarked and about to be swept
  on Crystal's thread list: no — it has either not published yet or exited
```

Rooting every `Thread` for its whole life did **not** fix it (4 of 40 with
`GCRY_THREAD_BIRTH_DEATHS=0`, which releases nothing ever), so the victim is
not the `Thread` object. It is a 16-byte block with no holder anywhere —
unidentified.

## What shipped

- **The birth root now ends at death, not at publication.** The
  `pthread_detach` / `pthread_join` hooks mark the slot before their real
  libc call — ordered, because a handle is not reusable until that call
  returns, so the mark cannot land on a slot a later `arm` has reused. The
  collector drops the root one collection later; a handle glibc hands to a
  new thread is proof its previous owner is gone and is reclaimed at once.
  The table is sized for live threads (64 → 256) rather than unpublished
  ones. Result over 960 short-lived threads: `outstanding` **4**,
  `overflows` **0**, against 961 and 705 with the release policy restored.
- **The staging table's occupancy is an atomic bitmask with a derived
  count.** It was a `Bool` array beside a plain `Int32` maintained with
  `+= 1` / `-= 1` from several thread classes; the counter drifted upward
  and never came back, so `while staged_count > 0` looped over an empty
  table. A derived count cannot drift.
- **`GCRY_THREAD_UNSTAGE_ON_DEATH=1`** — the reproducer above, off by
  default, documented as a reproducer rather than a knob.

## What did not ship, and why

- **Dropping the staging record at death.** Right on its face, and it is the
  reproducer. It goes in when the death window is closed, not before.
- **A yielding second phase for the staged wait.** The reasoning was sound —
  a thread that has not published is usually one that has not been scheduled
  — and the measurement said no: 8 runs of 400 collections each way, 2
  timeouts in 3 191 waits with a 2 ms yield budget against 2 in 3 185
  without, and every time the phase engaged it timed out anyway. What
  actually moved that number from 398-of-400 to ~0 was the counter drift.

## Three wrong turns, recorded

1. **A lock-free ring for death notices**, on the theory that a dying thread
   must not edit the birth table directly. The ring reset its producer index
   while a producer could hold a claimed slot. It was also unnecessary: both
   hooks post before their real libc call, so the ordering that makes direct
   marking safe was already there.
2. **"The ring race is the crash."** It was not — removing the ring left the
   rate unchanged (7 of 60 before, 7 of 60 after). The bisect that found the
   real cause was mechanical: revert one file at a time and count.
3. **Reading the first crash as new.** It was an old defect with its mask
   removed, which only the `HEAD` + pure-delay arm could distinguish.

## Gates run

`thread-birth-root` (five arms), `stw-epoch`, `stw-ack-window`,
`find-block-race`, `stw-index-race`, `scheduler-roots`, `ec-queue-audit`,
`thread-storm-short`, `spec` (277), `spec-process` (32), `lint` (150),
`knob-doc-check` (173). The churn arm: 0 failures in 40 runs.

## The obvious fix, attempted and withdrawn

With the acknowledgement no longer needing a `Thread` object
(`../2026-09-12-stw-ack-birth-window/`) and the birth root now naming every
thread gcry has seen created and not seen end, the invisible set is
computable: **armed handles minus Crystal's list**. Suspend those like any
other thread, snapshot their bounds in the same pass, scan them from their
recorded SP. It was built — collect, suspend, wait, scan, resume, behind
`GCRY_SCAN_UNLISTED_THREADS` — and withdrawn. Two failure modes, both
fatal, both about the same missing fact: **there is no safe way to ask
whether a `pthread_t` still names a thread.**

1. **Asking libc segfaults.** Guarding the handle with `pthread_kill(id, 0)`
   before touching it — which is what the abandonment path already does —
   crashes on the *first* collection, deterministically, 3 of 3. A slot can
   outlive its thread by the grace collection, and probing such a handle
   dereferences a freed `struct pthread`. That is the `+0x418` shape this
   family has been chasing, reached from the other direction: the probe is
   not a safe guard, it is an instance of the defect.
2. **Not asking hangs.** Dropping the probe and trusting gcry's own death
   marks (the `pthread_detach` / `pthread_join` hooks) removes the crash —
   and a thread that dies between the mark being read and the signal being
   sent never acknowledges, so the stop waits out its resends and then
   reaches the same unsafe probe. One run in three hung.

The set is also empty in the workload that crashes: `unlisted_seen=0` over
120 collections, because at a stop every thread has either published or been
marked dead. So the mechanism cost two fatal modes and covered nothing
measurable.

What is left, and what the next attempt should start from: the dying thread
is the only party that can safely speak for its own handle. `GC.pthread_detach`
already runs **on** it, where `pthread_self()` is valid by construction — it
can publish its own bounds and SP and then park cooperatively, the way the
Monitor does, instead of being signalled. That covers `detach` to exit
without a single stale-handle question. It does not cover
`Thread.threads.delete` to `detach`, which is where `Fiber.inactive` runs.

## What the reproducer actually crashes on — corrected

The first reading of it, recorded above, called the dying thread the user.
That was wrong, and the correction is the most useful thing in this file.

Two manifestations, and which one appears depends on the poison:

- **Bare**, exit 5, ~15–20% of runs: an exception, not a fault.
- **With `GCRY_POISON_FREED=1`**, SIGSEGV: the poison read at +8 of a
  16-byte block, no holder in roots, heap or fiber stacks. Poison changes
  the timing enough that this arm almost never fires (0 crashes in 534
  runs), which is why the bare arm is the one to drive.

The bare arm's exception, and its stack:

```
Tried to raise:: pthread_mutex_unlock: Invalid argument (RuntimeError)
  Thread::Mutex#unlock
  Thread::LinkedList(Fiber)          ← Fiber.fibers.push
  Fiber#initialize<Pointer(Void), Thread>
  Fiber::new<Pointer(Void), Thread>
  Thread#start                       ← a thread being BORN
  Crystal::System::Thread::thread_proc
```

So the thread is **starting**, not dying: `Thread#start` has already pushed
itself and set its TLS and is building its main `Fiber`, which pushes onto
`Fiber.fibers` and takes that list's mutex. The `unlock` comes back
**EINVAL** — not EPERM, which is what an error-checking mutex returns for a
non-owner — so the mutex memory is not a valid mutex. `Fiber.fibers`, or the
`Thread::Mutex` it holds, has been reclaimed or overwritten.

A second sighting lands in the Monitor instead
(`Fiber::ExecutionContext::Monitor#run_loop`'s `every` rescue, then a SEGV
inside DWARF decoding while printing the exception) — same `EINVAL`, a
different consumer. The DWARF fault is noise, but destructive noise: it
turns the report into a recursive backtrace storm, which is why the first
legible reading took several attempts.

Sizes ruled out by measurement, since the 16-byte block cannot be any of
them: `Thread` 184, `Thread::Mutex` 48, `Fiber` 176, `Fiber::StackPool` 24,
`EC::ThreadPool` 48, `Thread::LinkedList` 32, `Fiber::Stack` 24. So the
16-byte victim carries no `type_id` — a raw `Array`/`Deque`/`Hash` buffer or
a closure box — which is also why the dying-type audit cannot name it.

## A soundness hole found on the way, and closed

Every thread the stop suspends by signal has its GP registers spilled into
the `ucontext` and scanned, because — the collector's own words — a
reference can live only in a register. **The Monitor is never signalled**, by
design: a resume race leaves it in `sigsuspend` forever. It waits out the
stop in `MonitorGate.enter` instead, and it was the one thread whose
registers nothing captured. It parks there on **238 of 240** collections in
this workload, so the hole is on a hot path, not a corner.

Closed by the pair the collector already uses on itself: the asm clobber
that forces live pointers out of registers, then `setjmp` into a **local**,
which the Monitor's own stack scan already covers.

Stated with its weight: this did **not** change the reproducer's rate — 56
of 258 runs with it against 49 of 252 without. It closes a hole; it does not
close this crash. A survival A/B cannot discriminate here for the reason
`make greg-roots --explain` gives about its own arm: whether a pointer lives
only in a register is a codegen outcome no source-level test can compel. The
gate is that the spill happens, counted as `monitor_reg_spills`.

## Open

The reproducer's defect. `Fiber.fibers`' mutex reads as uninitialised to a
**starting** thread, so the next question is what makes a class-variable
linked list and its mutex invalid — a missed static root, or memory reused
under it. The 16-byte victim has no `type_id`, so it is a raw buffer, and
naming it needs an instrument the audits do not have: they key on Crystal
types.

Two framings to drop, because both cost a day here: that the dying thread is
the user (it is a starting one), and that the `Thread` object is the victim
(rooting it for its whole life changes nothing).
