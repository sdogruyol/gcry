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

**Locally: zero.** `thread_storm` (200 × 12) and `ec_queue_audit --control` walk
the check every collection and never see a staged thread or an unbounded one —
consistent with a defect that does not happen here. **The silence is evidence
rather than an unarmed counter**: with `snapshotted_stack_bounds` stubbed to
return `nil`, the same run reports `6 listed, 0 bounded, 0 staged` at every
collection. The gate requires the walk to have run at all, and the control run
requires it not to have.

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
