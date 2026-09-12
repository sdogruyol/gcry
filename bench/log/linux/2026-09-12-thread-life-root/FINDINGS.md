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

## Open

The death window. It now has a reproducer that fires in seconds on one box,
which is more than this family has had since 2026-08-16, and the victim is a
16-byte block that no holder search accounts for. Naming it is the next step;
covering the window — scanning a dying thread's stack, or keeping it visible
until it exits — is the fix after that.
