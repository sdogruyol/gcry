# A chunk released with a live block in it, read for the first time

Date: 2026-09-14 · CI run `34787711949` (x86_64, 2 vCPU) · local host: AMD Ryzen
AI 9 465, 8 cores · tree: `96832b8`

## The sighting

One of the 18 overnight CI runs failed `make thread-churn-uaf` on its guarded
arm, and the report said something no sighting of this defect has said before:

```
gcry: SIGSEGV at 0x7f6e5cea0014 — in a chunk gcry RELEASED — base
0x7f6e5cea0000, 131072 bytes, empty size-class chunk release, at collection 206;
the write is 20 bytes into it. Collections since: 0.
Blocks still allocated at release: 1
```

It could say it because of the fix landed hours earlier: the release ledger used
to be consulted only for addresses *inside* the heap span, and releasing a chunk
is what moves an address out of the span, so exactly these faults used to print
"never a gcry allocation, so a swept object is not the explanation".

**"Blocks still allocated at release: 1"** is a popcount of the chunk's
occupancy bitmap taken at the moment of release. So this is not a stale mutator
pointer into memory that was legitimately freed: it is a live block inside
memory the collector gave back, and "Collections since: 0" says the write
happened in the same collection as the release.

## The window, from the code

1. The sweep decides a chunk is empty, unlinks it from `@chunks` **inside the
   stop**, and queues it on `@pending_empty_chunks`.
2. Its `@chunk_index` entry survives — `index_remove` runs in the post-STW
   flush, deliberately (`collect_sweep.cr`: "the entry leaves the index here,
   immediately before its memory goes").
3. The allocator resolves a pooled chunk address through **that index**
   (`bitmap_indexed_chunk`) and accepts the chunk if `bitmap_pool_candidate?`
   likes it — and that predicate accepts a chunk whose blocks are all free,
   which a chunk queued as empty is by construction.
4. Under multi-mutator STW the flush runs after `start_world`. So between the
   stop ending and the flush running, a mutator can legally take a block out of
   a chunk that is already queued for unmapping.

## The fix

Refuse. `flush_pending_empty_chunks_locked` now re-reads each queued chunk's
occupancy immediately before releasing it, and a chunk with any allocated block
is kept mapped and **put back on the live list** so the next sweep sees it
normally. Refusing cannot lose: a chunk kept costs RSS, a chunk unmapped under a
live block costs the object.

`refuse_live_release` did not cover this — it asks whether another *indexed
chunk* lives inside the range, not whether this chunk still holds blocks — and
under `GCRY_UNMAP_GUARD=1` it is not even reached, because `guard_release`
short-circuits the `unless A || B || C`.

Two counters make the state legible: `release_flush_chunks` (chunks the flush
considered) and `release_refused_occupied` (chunks it refused).

## What could not be reproduced locally, and why that is informative

The window was never reached on this host — 0 refusals in 24 churn children with
the flush held 20 ms, on 8 cores and pinned to 2, and 0 in a purpose-built
harness. The counters say why:

| workload | chunks the flush considered |
|---|---|
| churn, several mutators alive, 120 collections | **0** |
| single-threaded allocate/drop, 30 collections | **37** |

With mutators alive the sweep does not queue empties at all — they go dormant
and stay linked — so there is nothing to release and no window. Single-threaded,
the queue fills, but then there is no second mutator to take a block. Reaching
the window needs **both**: the sweep on its single-mutator path *and* a mutator
running when the flush walks the queue, which is the thread-birth window the
churn reproducer hits about once in twenty-four children on a 2-vCPU runner and
did not hit here in 48 attempts.

`GCRY_EMPTY_FLUSH_DELAY_MS` widens the second half and `GCRY_RELEASE_OCCUPIED=1`
restores the pre-fix behaviour for a control; `bench/occupied_release.cr` runs
both and refuses to pass when it reaches nothing, which is what it currently
does here. It is research, not a gate: a gate that cannot reach its own window
on the host it runs on proves nothing.

The test is the next CI sighting. Where the guarded arm printed a fault, it
should now print `refusing to release chunk 0x… — the sweep queued it empty and
N block(s) are allocated in it now`.

---

# Part 2 — the kept chunk is anonymous, and naming it smashed the stack

Same day, tree `4c1e1b6` → `ab2114b`, same host.

## Why the refusal needs a ledger

A refused chunk goes **back on the live list**, which makes it an ordinary
chunk again. Nothing in a later crash report distinguishes it: if it is
released for real afterwards and a stale pointer faults on it, the report says
`in a chunk gcry RELEASED …` like any other release, and the window this defect
is about leaves no trace in the one document a reader gets.

So each refusal records base, length, collection and occupancy into a
sixteen-slot ring (`note_kept_release`, four stores on a path that already
walks the chunk), and the report asks it in **both** branches a fault can land
in — in-span with no live block, and out of span. Out of span matters for the
same reason it did in part 1: releasing a chunk is what moves its address out
of the span.

## The control, because the window does not open here

`GCRY_REFUSE_EMPTY_RELEASE=<n>` refuses the first n empty-chunk releases
whatever the occupancy says. A budget rather than a flag: a chunk refused
forever is never released, and the line under test is the one a *later* release
prints. `make kept-release-report` keeps a chunk, lets it go under
`GCRY_UNMAP_GUARD=1` (so the range stays mapped `PROT_NONE` and the read
faults rather than silently succeeding), reads a saved address in it, and
requires the report to name both:

```
child: victim 0x7fe1d73b7c20 kept=true
gcry: this chunk was KEPT by a refused release - base 0x7fe1d739f000, 131072
bytes, at collection 3 with 0 block(s) allocated in it at the time. […] 0
blocks means the refusal was forced by GCRY_REFUSE_EMPTY_RELEASE, not the window
gcry: SIGSEGV at 0x7fe1d73b7c20 — in a chunk gcry RELEASED — base
0x7fe1d737f000, 524288 bytes, empty size-class chunk release, at collection 4;
the write is 232480 bytes into it. Collections since: 20. Blocks still
allocated at release: 0
```

The two lines are complementary rather than redundant, and the sizes say why:
the release names a **524 288-byte run**, because `flush_release_runs`
coalesces contiguous chunks into one `munmap`, while the refusal names the
**131 072-byte chunk** inside it. Neither line can be derived from the other.

The `0 blocks means the refusal was forced` clause exists so the control cannot
read like a sighting: the window is defined by a mutator having taken a block,
and this knob keeps chunks nobody touched.

## A control must not spend the sighting's numbers

The first version of the knob bumped `release_refused_occupied`, which is the
field part 1 introduced to mean *the window was hit and the collector was
protected*. Two costs, both silent:

1. Every control run reports 64 window hits on a host where the window has
   never opened once.
2. The shipped one-shot diagnostic — `refusing to release chunk 0x… — the
   sweep queued it empty and N block(s) are allocated in it now` — fires on
   `release_refused_occupied == 1`. The control spends that on its first
   forced refusal, so a *real* refusal later in the same process prints
   nothing. The knob would have silenced the line it exists to sit beside.

Forced refusals are counted in `release_refused_forced` instead, and the gate
pins the split from the child:

```
child: refusals forced=64 window=0
```

Observed red by counting both in one field again: `the knob refused nothing
(forced=0 window=64)` and `64 refusal(s) were counted as the window`. A
non-zero `window` here is not a gate bug — it is a sighting, and the failure
text says to go read `refusing to release chunk` above it.

## The gate passed while the report was dying

The first green run was false. Under the PASS line the child had printed:

```
gcry: the crash report faulted inside itself, while searching nothing — the
fault is not inside the search, at 0x0, signal stack 0x7f61094e0000 + 262144 B,
253672 B left below this frame. The report is the defect here, not the crash it
was describing
```

8.5 KiB of a 256 KiB signal stack used, so not depth. `gdb` with
`handle SIGSEGV nostop pass` and a breakpoint on `_exit`:

```
#0  _exit ()
#1  handle () at src/gcry/segv_report.cr:251
#3  <signal handler called>
#4  report_kept_release () at src/gcry/segv_report.cr:810   ← RawOut.flush
#5  0x73206b6e75686320 in ?? ()                             ← " chunk s"
#6  0x646168206c6c6974 in ?? ()                             ← "till had"
```

Frames 5 and 6 are the message itself. `RawOut.append` stops at `LIMIT` (480 B)
and is handed a bare pointer, so it cannot see the end of the caller's array:
the kept-release line is **377 bytes and its buffer was 256**.

What the 121 bytes past the end did, in order:

| clobbered | symptom |
|---|---|
| `occ` | the line printed `0 block(s) allocated` and then, two clauses later, `A mutator took one` — the branch for a non-zero count |
| return address | the report exited at `0x0` **inside itself**, with `gcry: SIGSEGV at …` still unflushed in the caller's buffer |

The report lost exactly the part it exists for. Widest possible kept-release
line is 453 bytes with every number at full width, so `UInt8[RawOut::LIMIT]`
holds it untruncated.

## The class, measured

Thirty-three buffers were below the writer's limit. Two others could already
run past their end:

| site | buffer | widest line | ordinary line |
|---|---|---|---|
| `segv_report.cr` kept-release | 256 | 453 | **377 — observed smash** |
| `collect_scan.cr` index/list disagreement | 352 | 417 | 349 — **three bytes of margin** |
| `thread_list_tripwire.cr` chunk-index line | 288 | 295 | 221 |

All thirty-three are `UInt8[RawOut::LIMIT]` now. `make raw-buf-check` fails the
build on a buffer smaller than the writer that fills it, and asks the same of
the two hand-rolled writers that predate `RawOut` — `EcQueueAudit` stops at 300
with 320-byte buffers, `StwWatchdog` at 250 with 256, both already sound. The
invariant is about the pair, which is why the check reads the limit out of the
source rather than hard-coding 480.

## The gate now fails on all three symptoms

Observed red with the 256-byte buffer restored, green with it at `LIMIT`:

```
FAIL: the report faulted inside itself after naming the chunk. […]
FAIL: the kept-release line printed and the report's own description of the
      faulting address did not, so the report died between them
FAIL: the report read a non-zero block count for a chunk the knob kept. […]
```

A gate that asks only whether a line appeared will pass a process that dies
printing it.

## Verification

`make kept-release-report`, `released-range-report`, `segv-report`,
`mark-audit`, `thread-block-audit`, `raw-buf-check`, `knob-doc-check` (186
knobs); `make thread-churn-uaf` both layouts — shipped arms 0 of 24 including
the new `reported` arm, both controls still reproduce (7 of 8 poisoned);
`make spec` 277/0, `make spec-process` 32/0, ameba 150/0, format clean.
