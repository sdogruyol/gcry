# The dying `Thread`'s address lives on a stack gcry owns nothing of

2026-08-20. Ten reruns of the `test (aarch64 native)` job on `f3b9055`
(PR #27), which is the first commit carrying `GCRY_THREAD_BLOCK_AUDIT=1` on
`scheduler-roots` and `ec-queue-audit`.

**4 of 10 failed, and all four printed the same finding.** Every failure is
`ec-queue-audit`, every one at **collection 2**, every one with exactly one
dying-type report.

| rerun | dying block | region holding it | classifier saw | fault |
|---|---|---|---|---|
| 1 | `0xff15e39ff208` | `[0xff15a5800000,0xff15a6800000)` | 100 fibers / 0 pooled / **4** thread bounds | `0x0` |
| 5 | `0xff1572c1f2d8` | `[0xff1535000000,0xff1536000000)` | 98 fibers / 0 pooled / **4** thread bounds | `0x1000008` |
| 7 | `0xfff4b9adf068` | `[0xfff47a800000,0xfff47b800000)` | 96 fibers / 0 pooled / **4** thread bounds | `0xdeadfff4b9aa3df8` |
| 9 | `0xff50053daec8` | `[0xff4fc5000000,0xff4fc6000000)` | 100 fibers / 0 pooled / **5** thread bounds | `0xdeadff50053daec8` |

Raw output in `catch-1.log`, `catch-5.log`, `catch-7.log`, `catch-9.log`.

## The identification chain is closed

Rerun 9, in full:

```
gcry: dying-type audit — block 0xff50053daec8 size 192 type_id 173 is unmarked
      and about to be swept. In a suspended thread's registers: no (of 93 words).
      Offered by the collecting thread's own stack scan: no. collection 2
…
gcry: SIGSEGV at 0xdeadff50053daec8 — gcry's freed-block poison … a use-after-free
  → Gcry::Platform::pthread_stack_bounds
  → Gcry::Platform::snapshot_pthread_stack_bounds
  → Gcry::Heap#stop_world
```

`0xdeadff50053daec8` is the tag `0xDEAD` over `0xff50053daec8` — **the same
block the audit named one collection earlier**. Until now the crash named the
block and nothing named its death; the two halves are now the same block, in the
same run, one collection apart.

The other three are weaker and are worth stating as such: rerun 7's poison names
`0xfff4b9aa3df8`, a *different* block from the one the audit reported, and
reruns 1 and 5 fault on `0x0` and `0x1000008`, which name nothing. One exact
match out of four, not four.

## The holder, and it is the same shape every time

Six base hits, and in all four runs every one of them is in a single **16 MiB
anonymous `rw-p` mapping** that the classifier can name as neither a heap block,
a fiber stack, a pooled stack, nor a thread stack. The offsets below the
mapping's top are **byte-identical across all four runs**:

```
0x1850  0x1800  0x1768  0x1760  0x1758  0x0A40
```

Six words, at the same six offsets, in four independent processes. A region
mapped whole and written only near its top, with a frame layout that repeats
exactly, is a **stack** — and the same run's classifier had **4 or 5** thread
stack bounds to compare against while ~100 fibers were live.

One of the four crashes lands in `Fiber::ExecutionContext::ThreadPool#attach` ←
`Thread#start` ← `Crystal::System::Thread.thread_proc`, i.e. on the **new
thread's own start path**.

So the reading is: the `Thread` object is reachable only from the stack of a
thread that is starting, gcry has no bounds for that stack, the scan offers
nothing from it, and the sweep takes the object. A missing root source — the
same shape as both defects v0.19.0 closed. `bench/log/linux/2026-08-17-thread-birth-window/FINDINGS.md`
argued this window from Crystal's source and measured it at roughly one
collection in a thousand; this is the first time an object has been caught
dying in it.

**What separates the two candidate mechanisms is not yet in the log.** A stack
with no bounds is either a thread that has not published itself on Crystal's
list (the birth window, which `Platform` already records from `pthread_create`)
or a thread that *is* on the list and whose bounds the snapshot failed to read
(the visited/read gap, countable since v0.20.0). The fix differs, so the report
now prints the thread population beside it — Crystal's list, how many of those
have snapshotted bounds, how many are staged and unpublished, and what the
kernel says the process has. The next catch decides it.

## The heap holders at fault time are not holders of this object

Rerun 9's `GCRY_POISON_HOLDERS` search, run at the *fault*, found six live heap
blocks pointing at `0xff50053daec8`, including another `type_id 173` block. That
is not a contradiction of "no heap holder at death" — the same report says the
block has **since been REISSUED**, so what points at it now points at whatever
occupies it now. The address-space audit, which ran inside the collection that
freed it, found **zero** hits in any gcry block.

## What a correctly collected `Thread` looks like, and it is not this

A dying `Thread` is not by itself a defect: a thread that has exited and left
Crystal's list *should* have its object reclaimed. So the report needs a
baseline, and `thread_storm` — whose whole job is creating and joining threads —
supplies one. Eight local runs, 200 iterations × 12 workers, arm on:

- **0 crashes**, and **72** dying `Thread` blocks reported;
- **432 reported holders, and every single one is "the collector's own call
  chain, this audit's included. Not evidence"**.

That is what a correctly collected `Thread` looks like: at the moment it dies,
nothing in the address space points at it except the instrument's own frames.
None of the 432 is in a heap block, a fiber stack, a pooled stack, a thread
stack, or an unowned mapping.

Against that baseline the four CI catches are a different object entirely: six
holders, none in the collector's chain, all six in one unowned stack-shaped
mapping.

## And in the harness that fails, a dying `Thread` *is* the crash

`ec_queue_audit` keeps its threads for the length of the run, so a `Thread`
object dying in it is never routine. Across the two aarch64 batches — 20 reruns
of the same job — the correlation is exact:

| | dying-`Thread` report | no report |
|---|---|---|
| **crashed** | 4 | 0 |
| **green** | 0 | 16 |

Locally the same harness says nothing at all: **40 runs, 0 crashes, 0 reports**,
with `GCRY_EC_QUEUE_AUDIT=1 GCRY_POISON_HOLDERS=1 GCRY_THREAD_BLOCK_AUDIT=1` on
x86_64. The defect is not being missed locally by an instrument that cannot see
it — the instrument fires 72 times in `thread_storm` on the same machine. It is
not happening here.

## All four catches are in the arm with the queue audit **off**

`ec-queue-audit` runs the harness twice: once with `GCRY_EC_QUEUE_AUDIT=1`, and
once as `--control` with it off. **All four catches are the control run.** 4 of 4
is not proof of a preference, but it is enough to sample by: the first version of
`make thread-uaf-sample` ran only the audit-on arm and found nothing in ten CI
runs, which is what a sampler aimed at the wrong arm looks like. It now runs both
arms per iteration, as the gate does.

Worth stating and not explaining away: with the queue audit on, every collection
does an extra bounded walk of the run queues *inside the pause*. That lengthens
the stopped world, and a race whose window is the birth of a thread can be
masked by a longer pause as easily as by anything else. Timing, not mechanism —
but it is the difference between the two arms.

## Measuring the precondition, because the consequence comes in bursts

Two more batches after the first: 10 native jobs (**0/20** harness runs) and two
sampler jobs (**0/20** and **0/20**). The rate is not stable — batch 1 fired 4
times in 20 and everything since has been silent, on the same fleet and the same
commit family. Waiting is not a plan.

The consequence is rare; its **precondition is countable in every collection**.
A `Thread` can only die on an unscanned stack if a thread exists whose stack
gcry has no bounds for, and there are exactly two kinds — the two candidate
mechanisms:

- **staged**: created, recorded by `Platform` at `pthread_create`, not yet on
  Crystal's list, so `stop_world` neither suspends nor scans it;
- **a gap**: on the list, and the pre-stop snapshot got no bounds for it.

The arm now counts both at every collection and reports the first few sightings
of each (`thread_pop_collections` / `_gap_collections` / `_staged_collections`).
A green CI run now says something either way: preconditions present names the
window without another crash; none at all says the unowned stack in the catches
is neither of these and the hunt widens.

### The first version of the staged count was zero by construction

It asked `Platform.staged_count` after the mark and got zero everywhere, which
was not a measurement: `wait_for_staged_threads` runs *before* the world stops
and either drains every entry that has published or, on timeout, **drops the
rest** — so nothing downstream can ever see one. That is the same failure the
Darwin RSS reader had for three releases, and it took ten CI runs to notice.

What the arm reports now is three distinct things:

- **what the wait saw at entry** — the birth window existing at all;
- **whether the wait gave up** — the world then stopped with a thread
  unpublished, which is the defect's precondition exactly;
- **a thread staged *after* the wait ran** — created once the collector was
  already past the point where it looks, so nothing waited for it at all. This
  one is not zero by construction: entries are otherwise released only when the
  thread publishes.

### And with that, the window is measurable — and locally the wait covers it

`ec_queue_audit --control`, 12 local runs: **24 sightings of a thread staged
when the world was about to stop** (5 of them at once at collection 0, which is
the execution context's workers being created), and **every one caught by the
wait** — 0 timeouts, 0 staged after it. So the birth window is not hypothetical
in this harness; it is there in every run, and here `GCRY_STAGED_WAIT` closes it
every time. `thread_storm` says the same.

**Both branches that would say otherwise are shown to fire**, by staging an id
that can never publish (`make thread-block-audit`, arms `staged` and
`staged-nowait`): with the wait on it gives up and says so; with
`GCRY_STAGED_WAIT=0` nothing waits and the entry is still outstanding when the
world stops, reported in 3 of 3 collections. A real thread cannot be held in
that state by a harness — it publishes in microseconds — which is why the id is
planted. Broken on purpose and observed red in both assertions.

So a CI catch now has three questions answered by the same report: was a thread
being born, did the wait give up, and was one staged after the wait. The
`gap` half — a listed thread with no snapshotted bounds — is measured the same
way, and its silence is evidence too: stubbing `snapshotted_stack_bounds` to
`nil` makes the same run report `6 listed, 0 bounded` at every collection.

## What green CI runs say, and what it leaves

Twenty green harness runs on the aarch64 runner, with the precondition walked in
every collection:

| | sightings |
|---|---|
| a thread staged when the world stopped, **caught by the wait** | 40 |
| the wait **gave up** | 0 |
| a thread staged **after** the wait ran | 0 |
| a listed thread with **no snapshotted bounds** | 0 |

Identical numbers in every run — 5 staged at collection 0 (the execution
context's workers), 1 at collection 8 — and identical to the local runs. So the
birth window is real, present in every run of this harness, and closed by
`GCRY_STAGED_WAIT` every time a green run looks.

That does not explain the catches, and saying so is the point: the staged
mechanism is measured and covered in every run where it can be measured. Either
the crashing runs differ in a way only a catch will show, or the unowned stack
in them is not a thread being born at all.

## The question that splits it, answerable on every catch

A dying `Thread` is either still on Crystal's list or not, and the two are
different defects:

- **on the list** — `Thread.threads` is a class variable, so the list is a
  static root and everything on it should be reachable. A listed `Thread` dying
  means that root is not covering it: root coverage, the family v0.19.0 closed
  twice.
- **not on the list** — the thread exited, `start`'s `ensure` removed it, the
  object *is* garbage and the sweep is right. The defect is then downstream:
  something still walks to it. `Thread::LinkedList` is **intrusive** — `@next`
  and `@previous` live on the `Thread` objects themselves — so a freed and
  reissued node puts garbage in the chain that `Thread.unsafe_each` follows, and
  that walk is exactly where `snapshot_pthread_stack_bounds` faults.

The report now answers both, on any catch, without needing the address-space
walk to find a holder: whether the block is on the list, whether any **live**
thread's `@next`/`@previous` still points at it, and how many links were read —
plus a self-check that the walk can find the collecting thread at all, because a
"not on the list" from a comparison that matches nothing is not a finding.

Locally, `thread_storm`'s dying `Thread`s answer *not on the list, not linked,
self-check found, 4 links read* every time: a thread that exited, removed
cleanly, correctly collected. That is the baseline the next catch is read
against.

## The catch that names it: the wait gave up, and the `Thread` died in that collection

2026-08-20, later the same day. Two more catches, one on the push run and one on
the pull-request run of `51d817d`, both on aarch64 CI, and this time the
precondition and the death are in the **same collection**:

```
gcry: dying-type audit — precondition: the wait for a staged thread GAVE UP —
      the world stopped with it unpublished. 5 listed, 5 bounded, 2 staged. collection 2
gcry: dying-type audit — block 0xffd0fe28ad28 size 192 type_id 173 is unmarked
      and about to be swept … On Crystal's thread list: no … collection 2
gcry:   threads at that moment: 5 on Crystal's list, 5 of them with snapshotted
        stack bounds, 0 staged and unpublished (5 ever staged), the kernel says 6
gcry:   0xffd0fe28ad28 held at 0xffd0be7fe7b0 … 16384 KiB anonymous mapping, hit
        6224 bytes below its top — mapped whole and used from the high end: the
        shape of a thread stack
gcry: SIGSEGV at 0xdeadffd0fe28ad28 — gcry's freed-block poison … a use-after-free
```

The second catch says the same at collection 5. In both, the poison the crash
faults on is the tagged form of the block the audit named — the second and third
exact matches, after the first on 2026-08-20 morning.

Read together with the green-run baseline (40 sightings, all caught by the wait,
never a timeout), the chain is:

1. `pthread_create` returns. gcry stages the id; the new thread has not yet
   pushed itself onto `Thread.threads`.
2. A collection begins. The pre-stop wait spins, the thread does not publish in
   time, and the wait **gives up** — it drops the staged entries and stops the
   world anyway. `5 listed, the kernel says 6`: one thread is outside the
   stopped world, in the same report.
3. That thread's `Thread` object is off the list, so the static root that is
   `Thread.threads` does not cover it, and its only holder is the new thread's
   own 16 MiB stack, which gcry has no bounds for and never scans. The mark
   cannot reach it. The sweep frees it.
4. The thread then publishes itself. The **next** `stop_world` walks the list,
   reads `@system_handle` out of the freed — by then reissued — block, and hands
   it to `pthread_getattr_np`. That is the fault seen since 2026-08-16, and the
   `+0x418` that never varied.

`catch-birth-1.log` and `catch-birth-2.log`.

**What is still an inference, and stated as one.** The report cannot yet prove
the dying object *is* the staged thread's. Its `@system_handle` can be compared
against the ids the wait recorded, and that comparison is only *consistent with*
the identification: this file's own local runs show the same `pthread_t` value in
eight different collections while the staged total climbed 4 → 11, i.e. glibc
recycles ids. What is not an inference: the wait gave up, a thread was outside
the stopped world, an off-list `Thread` died in that collection, and its only
holders were on a stack nothing scans.

## Two corrections the same catch forced, both in this instrument

- **"not on the list" was reported as "the thread has exited and the object is
  garbage".** Off-list has two causes and the first catch to reach that line was
  the other one — a thread that had not published *yet*. The line now states
  both and quotes the wait's own record beside it.
- **The report grew past `RawOut::LIMIT` (480 bytes) and was silently
  truncated**, losing the end of its own verdict. It is three lines now. That is
  the same failure this file has recorded three times in the crash reporter,
  committed by the instrument written to fix it.

## A reporter bug this catch exposed, and fixed

The same report said:

> that block, `0xff50053daec8`, since REISSUED, size 192, flags 0x400 — freed by
> an **explicit free**, not by the sweep

`0x400` is mark generation 4 with `FREE` and `SWEPT` both clear: the flags of a
block that is **in use**. `SWEPT` is set beside `FREE` by the sweep's freelist
link and cleared when the block is handed out again, so on a reissued block it
describes the reissue and not the free. This is the third false "explicit free"
from that line — twice from a misdecoded address in the 2026-08-16 hunt, and now
once against a block the dying-type audit had watched the **sweep** condemn one
collection earlier.

It now declines the verdict when the block is not still free, and says why. The
`segv-report` gate has a `reissued-poison` arm for it: plant a block, free it
with the tag on, get it reissued, fault on the saved poison, and require the
report to name the reissue and to name **no** free path. Broken on purpose and
observed red in both assertions; an arm that cannot get the block reissued fails
rather than passing on a still-free one.

## Caveats

- **The walk is truncated in every catch.** It stops at 512 MiB, and all four
  say `TRUNCATED`. There may be holders it never reached, so "the only holders
  are on that stack" is a statement about 514 MiB and not about the address
  space. The message now quantifies what it never searched.
- The audit fires at most once per collection per arm, so a collection that
  killed more than one `Thread` reports one of them.

## The control batch: the arm does not move the rate

Ten reruns of the same job on **master** (`7a7dd05`, no arm), same runner, same
afternoon: **3 of 10 failed**, all three the same defect — `pthread_stack_bounds`
← `snapshot_pthread_stack_bounds` ← `stop_world`, faulting at
`0xffe767000358`, `0xff10144000d8` and (with poison) `0xdeadff47f45ded28`.

| batch | arm | red |
|---|---|---|
| PR `f3b9055` | `GCRY_THREAD_BLOCK_AUDIT=1` | 4/10 |
| master `7a7dd05` | none | 3/10 |

So this gate's red rate on this runner is ~30% either way and 4/10 is not the
arm's doing — which was the only reading the first batch could not exclude by
argument alone. What the arm changes is not the rate but what a red run *says*:
the three control failures name a fault address and nothing about who held the
object.

## A third over-claim, from the control batch

All three control failures printed:

> `gcry: SIGSEGV at 0xffe767000358 — outside gcry's heap span […] — never a gcry
> allocation, so a swept object is not the explanation`

two lines after:

> `gcry: the collector was inside the pthread stack-bounds query for thread
> 0xffe766ffff40`

`0xffe766ffff40 + 0x418 = 0xffe767000358`. The fault *is* a field of the
descriptor that the in-flight `pthread_t` points at, that id came out of a
`Thread`'s `@system_handle`, and a `Thread` whose block was reclaimed and then
reissued carries no poison — so it reads as an ordinary value. The report was
excluding, by name, the exact mechanism this file is about.

Fixed: while a stack-bounds query is in flight, a fault a small fixed distance
past the id being queried is named as a descriptor field and a swept object is
called the *leading* reading rather than an excluded one. The decision is a pure
function (`SegvReport.out_of_span_reading`) with five cases in
`spec/segv_report_spec.cr` — including the two that must **not** be read as an
offset into the descriptor, an address below the id and the id itself — because
the branch that matters can only fire while libc is inside the query, which no
harness can enter.

That is three corrections to this reporter from one defect. The pattern in all
three is the same: a state read *after* the event being explained (flags after a
reissue, an address after libc's indexing, an exclusion made without asking what
the collector was doing), presented as a fact about the event.

## The fix, and why it touches nothing the collector does

The window is between `pthread_create` returning and the new thread's own push
onto `Thread.threads`. Three ways to close it were on the table: never give up
in the pre-stop wait (a thread that dies before publishing then wedges the
collector), snapshot and scan the staged thread's stack (`pthread_getattr_np` on
an id whose thread may already be gone — the very call this defect faults in),
or defer the collection on timeout.

None of them is needed, because **the object is already in gcry's hands**.
Crystal's `init_handle` calls

```crystal
GC.pthread_create(thread: pointerof(@system_handle), attr: …,
                  start: ->Thread.thread_proc(Void*), arg: self.as(Void*))
```

— the `Thread` *is* the `arg` the hook is handed. `src/gcry/thread_birth_root.cr`
roots it there and releases it in `stop_world`'s existing walk of Crystal's list,
which is exactly the moment the list becomes its root. One `add_root` per thread
created; nothing about the stopped world changes.

### Gating a window that cannot be held open

A real `Thread` publishes itself in microseconds, so no harness can hold it in
the state the defect needs. The gate creates a **raw** pthread through the same
hook with a plain heap block as `arg`: that thread never joins Crystal's list,
so the block stays unrooted-except-by-the-fix for as long as the harness likes.

| arm | victim | births armed |
|---|---|---|
| rooted | **survives**, contents intact | 2 |
| `--noroot` (same records, roots nothing) | **dies** | 2 |
| `GCRY_THREAD_BIRTH_ROOT=0` | **dies** | 0 |

The twin is what makes the first row mean anything: identical bookkeeping,
nothing rooted, and the block is collected. With the knob off the harness
reports *the window is open* — the defect, reproduced deterministically and
locally for the first time, in a harness rather than in one CI job in three.

### And the fix's own first version deadlocked

`release` called `heap.delete_root`, which takes `@roots_lock` — and
`stop_world_quiescing_roots` takes that lock and holds it across the whole stop.
It is a non-reentrant spinlock, so the first `GC.collect` never returned. The
release now hands the pointer back and the caller, already inside the lock,
mutates the set directly. Worth recording because the deadlock looked exactly
like the hang this collector had in `pthread_getattr_np` two weeks ago and is a
completely different thing.
