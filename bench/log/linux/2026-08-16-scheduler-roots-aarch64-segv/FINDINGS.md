# A SEGV in `pthread_getattr_np` — which turned out to be the use-after-free

> **Not aarch64-specific, 2026-08-17.** Run `32006847158` hit the same call, the
> same way, on **x86_64** — in `stw_mt_property_test`, a harness that uses plain
> `Thread.new` rather than execution-context workers. Every earlier sighting
> being on aarch64 was sampling, not a property of the platform. The title is
> kept for continuity; the "aarch64" in it is wrong.

> **Resolved as to mechanism, 2026-08-17 (occurrence 5).** This is not a
> separate defect and not a libc lifetime question. gcry was handed a
> `pthread_t` that was **gcry's own freed-block poison**, i.e. it read a
> `Thread`'s `@system_handle` out of a block that had already been freed. The
> sections below are the road to that, kept in order; the one that names it is
> "The fifth occurrence answers it".

2026-08-16. **Seen twice, in two different targets, within four hours.**

| run | commit | target | address |
|---|---|---|---|
| `31933855152` | `e7de946` | `make scheduler-roots` | `0xff42d3800358` |
| `31950823605` | `4645bf7` | `make ec-queue-audit` | `0xff00f1800358` |
| `31961004141` | `c28bea5` | `make ec-queue-audit` | `0xff6dbcc00358` |
| `31995517368` | `ea56fb8` | `make ec-queue-audit` | `0xff38b60000d8` |
| `31997472378` | `81123d2` | `make ec-queue-audit` | `0xdeadff86af17db50` (poison) |
| `32006847158` | `2a8a18b` | `stw_mt_property_test`, **x86_64** | `0x7f64e2e00348` |
| `32007492923` | `32dff1d` | `make scheduler-roots` | — |
| `32014723127` | `81eb56c` | `make scheduler-roots`, **x86_64** | `0x7fb0aa0005d0` |

Both `test (aarch64 native)`, both the same call chain, and both addresses end
in the same `800358`. A re-run of the first was green, which is why it was
filed as a one-off; the second arrived before that file was a day old. This
section is the correction.

## What happened

```
Invalid memory access (signal 11) at address 0xff42d3800358
  … pthread_getattr_np +84 in /lib/aarch64-linux-gnu/libc.so.6
  → Gcry::Platform::pthread_stack_bounds
  → Gcry::Platform::snapshot_pthread_stack_bounds
  → Gcry::Heap#stop_world
  → Gcry::Heap#run_collection → #collect → GC::collect
  → run<Bool> in bin/scheduler_roots
make: *** [Makefile:247: scheduler-roots] Error 11
```

## Why it is not the known flake — and why the second occurrence proves it

CI's recurring red is `make ec-queue-audit` dying on gcry's own poison
(`0xdeadf2eedeadf2d0` / `…f2fe`) — the open fiber-creation use-after-free. That
shape crashes *inside the audit's own workload* and the address is the poison.

This shape crashes inside `GC.collect` → `stop_world`, the address is an
ordinary-looking one, and the top frame is libc. The second occurrence landed in
`ec-queue-audit` — the same target as the poison flake — which is what makes the
distinction load-bearing rather than cosmetic: **"ec-queue-audit was red" is not
a diagnosis.** Two different defects fail that step, and only the backtrace
separates them.

| recent red runs | failing target |
|---|---|
| 31933855152 | **`scheduler-roots`** ← this one |
| 31931064682, 31901992333, 31901300298, 31886802497, 31871253977, 31868397807 | `ec-queue-audit` |

## Why it is not a deadlock, and what that leaves

The snapshot is taken **before** the suspend signals go out, under `Thread.lock`,
and the comment above it says why: `pthread_getattr_np` locks the *target's*
descriptor, so asking it about an already-frozen thread wedged the collector —
18 of 150 starts, fixed by moving the call out of the suspension window
(`bench/stw_startup_hang.cr`). That fix is not what broke here: this is a
**SIGSEGV inside libc**, not a hang.

What is left is the descriptor itself. `pthread_getattr_np` on a `pthread_t`
whose thread has exited reads freed thread-descriptor memory. `Thread.lock` is
held, so Crystal's list is not being mutated under the walk — but the list
holding a `Thread` whose pthread has already exited is not something the lock
prevents. That makes it the same family as `fix/stw-libc-under-suspension`:
gcry asking libc about a thread whose lifetime it does not control.

## The third occurrence, with the counters in

Run `31961004141` faulted the same way on the very first CI run after the
counters landed, and they answered:

```
gcry: the collector was inside the pthread stack-bounds query for thread
      0xff6dbcbfff40 — the fault is in that query, not in the heap.
      Visited/read so far: 22/21
gcry: SIGSEGV at 0xff6dbcc00358 — outside gcry's heap span
      [0xff6e07693000, 0xff6e07824000) — never a gcry allocation
```

Three facts that were not available for the first two:

- **The fault is inside the query**, stated rather than inferred from a libc
  frame, and the thread it is about is named.
- **`0xff6dbcc00358 − 0xff6dbcbfff40 = 0x418`.** The fault is 1048 bytes into
  the thread descriptor the `pthread_t` points at — libc reading a field of it —
  and the two addresses are on **different pages** (`…bff000` against
  `…c00000`). So the descriptor's first page is mapped and the next one is not.
  That is what a thread whose descriptor has been partially unmapped looks like,
  which is the exited-thread reading this file has been proposing.
- **22 visited, 21 read**, i.e. every earlier thread in this snapshot answered
  and the 22nd is the one in flight. There is no accumulated coverage gap
  hiding behind the crash; it is this call, on this thread.

Note also what the address line says on its own: *outside gcry's heap span*.
Without the in-flight id that is all the report could have offered, and it
would have read as a wild pointer rather than as a libc descriptor read.

## The fourth occurrence repeats the third exactly

2026-08-17, run `31995517368`. Same call, and the two instrumented crashes are
numerically identical where it matters:

| | thread id | fault | delta | visited/read |
|---|---|---|---|---|
| 3rd | `0xff6dbcbfff40` | `0xff6dbcc00358` | **0x418** | **22/21** |
| 4th | `0xff38b5fffcc0` | `0xff38b60000d8` | **0x418** | **22/21** |

The same offset into the descriptor, and the same position in the run — the
counters are cumulative, so "22 visited, 21 read" means the fault lands on the
**22nd stack-bounds query of the process**, twice. In both, the id sits near the
end of a page and `+0x418` crosses into the next one.

That is not a race with a random victim. It is a specific query, at a
reproducible point, on a descriptor whose following page is not mapped.

## Four mechanisms eliminated, from Crystal's own source

The obvious explanations are all ruled out by ordering in
`crystal/system/thread.cr` and `crystal/system/unix/pthread.cr` (1.21.0):

1. **"The handle is not published yet."** `thread_proc` assigns
   `th.system_handle = current_handle` *before* calling `th.start`, and `start`
   is what pushes onto the list. List membership therefore implies a written
   handle.
2. **"The main thread's handle is unset."** Its constructor assigns
   `Crystal::System::Thread.current_handle` before `Thread.threads.push(self)`.
3. **"The thread already exited."** `start`'s `ensure` runs
   `Thread.threads.delete(self)` *before* `detach { system_close }`, so removal
   precedes the pthread going away.
4. **"The list mutated under the walk."** `push` and `delete` both take
   `@mutex.synchronize`, and `Thread.lock` — which the snapshot holds — locks
   that same `threads.@mutex`.

So the thread gcry queries is in the list, alive, and carrying a handle its own
code wrote. None of the cheap stories survive.

**What that leaves**, and it needs runtime evidence rather than more reading:
either the id is valid but its descriptor is genuinely unmapped at that instant
(which would make it a libc/kernel-level lifetime question), or gcry hands
`pthread_getattr_np` something that is not the id it thinks it is.

**The discriminator is now built.** The snapshot remembers every id it has
successfully read bounds for (bounded at 64, and `stack_bounds_seen_full?` says
when it stopped recording so "first time" is never reported when the real answer
is "we stopped looking"). The crash report prints one of three lines:

- *had been read successfully before* → the thread stopped being queryable
  between two snapshots, despite the ordering above;
- *never been read successfully* → the first query for it is the one that
  faulted, and the startup path is back in scope even though the ordering says
  it should not be;
- *table is full, so this is not evidence*.

Gated in `process_spec` against a **live** thread id rather than a constant — an
always-false predicate would otherwise pass a test that only asked about an
unknown id — and broken on purpose in both directions: recording nothing fails
on `Expected: true`, an always-true predicate fails on `Expected: false`.

**Next**: the fifth occurrence answers it. No new instrument until then.

## The fifth occurrence answers it

2026-08-17, run `31997472378`, the first run after the "has this id ever been
read successfully?" line landed. It fired, and the id it printed settles the
whole thread:

```
gcry: the collector was inside the pthread stack-bounds query for thread
      0xdeadff86af17d738 — Visited/read so far: 25/24
gcry: that thread had never been read successfully — the first query for it is
      the one that faulted
gcry: SIGSEGV at 0xdeadff86af17db50 — gcry's freed-block poison … a
      use-after-free, not a wild pointer
```

**`0xdeadff86af17d738` is the poison.** `POISON_TAG` is `0xDEAD` in the top 16
bits and the freed block's address in the low 48, so this value is not a thread
id at all — it is what `GCRY_POISON_FREED` writes into a block at
`0xff86af17d738` when that block is released.

So `thread.to_unsafe` — the `Thread`'s `@system_handle` — was read out of a
**freed, poisoned block**. Everything else follows:

- The fault address is `0xdeadff86af17db50`, exactly `poison + 0x418`. That is
  glibc's fixed offset into `struct pthread`, applied to a poisoned value —
  which is why occurrences 3 and 4 both showed **`0x418`** and why the number
  never varied. It was never a descriptor offset that meant anything; it was
  arithmetic on garbage.
- "Never been read successfully" is right, and now for the obvious reason: that
  value was never a thread id, so no earlier snapshot could have read bounds
  for it.
- Occurrences 3 and 4 showed non-poison ids (`0xff6dbcbfff40`). Consistent: a
  freed block that has since been **reissued** no longer holds poison, so the
  handle read out of it is stale data rather than `0xdead…`. Same defect, one
  step further along in the block's life.

**And the four eliminations above stay true and stop mattering.** Crystal's
ordering is correct — the handle is published before the thread joins the list,
removal precedes `system_close`, and the list mutex is held. None of that
protects a `Thread` object whose *memory* gcry has already reclaimed.

So this is the fiber-creation use-after-free wearing a different hat, with one
new and useful fact: the object involved is a **`Thread`**, and `Thread` objects
are created by `Thread.new` and only pushed onto `Thread.threads` from inside
`start`, on the new thread. Between allocation and that push, the object is
reachable only from the creating thread's frame and the new thread's argument —
**the same birth window** `GCRY_BIRTH_GRACE` closes
(`bench/log/linux/2026-08-16-birth-grace/FINDINGS.md`).

## A reporter bug the same catch exposed

The report also said, of the same fault:

> the free that wrote it was of the block at `0xff86af17db50`, since REISSUED,
> size 192, flags 0x0 — freed by an explicit free, not by the sweep

**All of that is wrong**, and none of it should have been printed. `si_addr` was
the poison *plus* `0x418`; a poison with arithmetic done to it still carries
`0xDEAD` in its top bits, so the tag test accepted it and decoded an address
five blocks along. Its cleared flags then produced a false "explicit free" —
the second time in two days that a cleared `SWEPT` has been read as a verdict it
could not support.

Fixed two ways: the reporter now prefers the **registers'** copy of the poison
over `si_addr`, and refuses to decode any tagged word whose address does not
land on a block **base** — poison fills a payload with one repeated word, so a
genuine one always names a base. The offset case now prints "it lands N bytes
into a block, and poison always names a base, so it names no block", verified by
faulting on `poison + 0x418` on purpose.

## The counters are built

Both are in, and gated:

- `Gcry::Platform.stack_bounds_visited` / `.stack_bounds_read` — threads the
  snapshot walked against the subset it got bounds for, on `/gc-stats`. A gap is
  a thread whose pthread mapping the root scan does not have, and it is now
  countable rather than silent — the same shape as the register stubs v0.19.0
  closed.
- `Gcry::Platform.stack_bounds_in_flight` — the `pthread_t` being queried,
  non-zero only while `pthread_getattr_np` is running. The SIGSEGV report reads
  it first, before anything about the faulting address, so a repeat of this
  crash says **which thread** instead of leaving a libc frame.

Gated by `process_spec` (Linux; Darwin queries the descriptor at lookup time and
reports zeros by design, so the same assertion there would be red on a platform
that is working). Broken on purpose and observed red: making
`pthread_stack_bounds` return nil gives `visited=96, read=0` and fails the spec.

## What would settle it

The snapshot loop is `Thread.unsafe_each { |t| snapshot_pthread_stack_bounds(t.to_unsafe) }`.
Two facts would separate "exited thread" from "something else", and both are
cheap:

- count the threads the snapshot visits and the bounds it successfully reads,
  per collection, and expose the pair — a visit that returns nothing is already
  the shape the v0.19.0 register work was about;
- record the `pthread_t` the loop is on before the call, so a fault names the
  thread rather than the libc frame.

Both are now built and gated (above). The next occurrence should print the
thread id and the visited/read pair before the address line.

## One more thing the second run showed

The SIGSEGV report printed, on **aarch64**:

> the kernel reported address 0. On x86_64 that is also what a *non-canonical*
> dereference looks like …

The reasoning is x86_64-specific and the text says so, but it is being printed
on a platform where it does not apply. Small, and worth fixing while the file is
open: a diagnostic that explains the wrong architecture is how a reader gets
sent down the wrong path.

## And the sighting the same day wasted

Run `31953213205`, the next one, failed the *same step* on the **other** defect —
the open use-after-free — and the report could only say:

> the poison is untagged, so it names no block. `GCRY_POISON_TAG=1` writes the
> freed block's address into the poison and this line becomes the block that was
> freed

`make ec-queue-audit` was running `GCRY_POISON_FREED=1`. The tag costs nothing
extra — it is written by the same memset — and the local repro has gone quiet, so
CI is currently the only place this defect is observed. Both the gate and the
5 h soak arm now run `GCRY_POISON_HOLDERS=1` instead, which implies the poison,
the tag, the crash report and the holder search. The next CI catch names the
block, its size, whether the sweep or an explicit free released it, and what
still points at it.

## The instrument, 2026-08-19: ask the question about one type

The crash reports have taken this as far as they can. They say *what* was read
out of the freed block (`@system_handle`), and they say the block was a
`Thread`. What they cannot say is what still held that `Thread`'s address when
the collection freed it, because by the time the fault happens the collection is
over.

The fiber family answered exactly that question with
`GCRY_ADDRESS_SPACE_AUDIT` — at the moment of death, walk every readable mapping
in `/proc/self/maps` and name the region that holds the address. Pointed at this
defect, it never fires, and the reason is size in both halves of its trigger:

- the dying-register audit that calls it walks only size classes at or above
  `DYING_AUDIT_MIN_SIZE` (384 B, the `Deque(Fiber::Stack)` capacity band). A
  `Thread` is 192 B and is never looked at;
- and it fires once per collection, for whichever unreferenced block died first.
  In a program churning fibers that is never the `Thread`.

`GCRY_THREAD_BLOCK_AUDIT=1` (`src/gcry/thread_block_audit.cr`) aims the same
question at one type instead. After the mark and before the sweep — the only
window where "about to be freed" exists and nothing has been reclaimed — it
reads Crystal's `type_id` out of every used block, and for each block of the
watched type the mark did not reach it prints the block, whether its address is
in a suspended thread's registers, whether the collecting thread's own stack
scan offered it, and then hands the address to the address-space walk.

**It counts what it walked, and it counts the live blocks of the watched type.**
The second one is the qualifier that matters: a run reporting no dying `Thread`
is worth nothing if the arm is aimed at a `type_id` that matches nothing in the
heap, and those two cases are indistinguishable without it.

### Why it can be believed when it is silent

`GCRY_DYING_TYPE_ID=<n>` points the same walk at any other type, which is what
makes a gate possible at all — the harness cannot make a `Thread` die on
command, but it can make its own objects die. `make thread-block-audit`, three
arms:

| arm | what it requires |
|---|---|
| `dies` | 200 dropped objects of the watched type: at least one named as dying, **and** the address-space walk triggered |
| `lives` | the same 200 held in a rooted array: a non-zero *live* count and **zero** deaths |
| `thread` | the shipped default, four threads running: live `Thread` blocks found |

Broken on purpose in three directions and observed red: treating every block as
marked takes `dies` to 0 deaths and 0 audits; dropping the `type_id` comparison
gives `lives` **8 deaths among 200 rooted objects**; a bogus default id leaves
`thread` at 0 live with 245 blocks walked. The `--control` run has the knob off
and walks nothing, so the other runs' counts belong to the knob and not to the
`dying_type_id` property, which every arm sets.

### A correction the gate produced immediately

The first clean run of the `dies` arm reported six holders on the collecting
fiber's stack, and one of them was classified **"INSIDE the window the scan
used"** — which reads as "the scan walked those bytes and did not offer the
value", i.e. a filter bug in the root scan.

It was the instrument. The audit carries the target as an argument through a
call chain that runs *below* where the collector was entered, and the scan
window's low bound is deeper still, so the audit's own frames are inside the
window it compares against. The header of `address_space_audit.cr` already
records a first version that reported 47 hits that were its own frames; the fix
then — compare against the window the scan actually used — is not enough on its
own, and this is the second time the same instrument has found itself.

It now excludes everything below `collect_entry_sp`, which is the boundary
`GCRY_BIRTH_GRACE`'s holder search already uses for the same reason, and says
so instead of classifying it. After the fix all six are named as the collector's
own call chain (80 to 18 408 bytes below the entry SP) and none is offered as
evidence about the scan.

A second, smaller one: the dying audit's "never offered by the mutator-stack
scan" line reads a table that only records candidates in the ≥384 B band, so for
a 192-byte block the honest answer was "not recorded", not "not offered". The
table now also records blocks of the watched type whatever their size.

### Where it runs

On all three gates that have caught this defect — `scheduler-roots` and
`ec-queue-audit` (both architectures; six of the eight sightings are on the
aarch64 runner) and the x86_64 `stw_mt_property_test` step — plus its own gate
on the aarch64 job. Cost measured locally: **+3%** wall clock on
`stw_mt_property_test` (6.72 → 6.94 s), and nothing distinguishable on
`scheduler_roots` (0.054 → 0.048 s) or `ec_queue_audit` (0.228 → 0.225 s).
None of them reports a dying `Thread` locally, which is the expected result and
the whole reason the instrument had to be sent to CI.

## Status

**Both gates that catch this now carry the diagnostics.** `ec-queue-audit` and
the STW × TLAB property test got them first; `scheduler-roots` caught it twice —
aarch64 on 2026-08-16, x86_64 on 2026-08-17 — and said nothing but a hex number
both times, so it now runs with `GCRY_POISON_HOLDERS=1 GCRY_THREAD_CENSUS=1`
too. Three runs green locally with them on.

Mechanism **resolved** at occurrence 5; the underlying use-after-free is still
open. **8 occurrences**, in CI, across **three** gates (`scheduler-roots`,
`ec-queue-audit`, `stw_mt_property_test`) and **both** architectures. The last
of them, on x86_64, could say nothing — the diagnostics were not enabled on that
step, which is now fixed. Still
not reproduced on demand and never seen outside CI. It is no longer a one-off,
so the two counters proposed above are worth building rather than merely
proposing — and until they exist, a red `ec-queue-audit` on aarch64 has to be
read from its backtrace, not from its name.

**2026-08-19:** the counters exist, and so does the instrument that asks the
question they leave open — what held the `Thread`'s address when its block was
freed (`GCRY_THREAD_BLOCK_AUDIT`, above). It is gated, it is on all three gates
that have caught this, and it is silent locally. The next occurrence should
print the holder rather than only the fault.
