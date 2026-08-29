# The silent hang, named: a worker died and took the harness's counter with it

2026-08-29, Linux x86_64, 20-core box, children pinned to **two** cores
(`taskset -c 0,1`, six at a time) — the cheap reproducer the previous session
asked for, after CI hung 3 of 6 control children on a two-core runner.

What `../2026-08-27-stw-write-protocols/FINDINGS.md` left open: a child that
produces no output and dies on the deadline, 1 of 780 on the fixed tree, "not a
stuck STW (the watchdog is silent), rare, and it predates every fix made today".
That description was right about every fact and wrong about the implication —
the watchdog is silent because it is **correct**.

## The instrument that never worked

`hang_catch.sh` had run 580 children over an hour and read nothing from any of
them. Not because they refused to hang: because yama `ptrace_scope=1` (a stock
desktop default) lets only an **ancestor** attach, and the script's `gdb -p` is
a sibling of the child. Every capture it ever took says
`ptrace: Operation not permitted`.

`GCRY_ANY_PTRACER=1` on the bench child is the fix — `PR_SET_PTRACER_ANY`, the
child's own consent, armed by knob so an ordinary gate run is not made
inspectable to everything on the box. With it the first batch produced three
full backtraces.

## The reproducer

Six children at a time on two cores, `GCRY_MOSTLY_EMPTY=1 GCRY_UNMAP_GUARD=1`:

| arm | children | hangs |
|---|---:|---:|
| `GCRY_TRIM_IMMEDIATE=1` (control) | 66 | **20** |
| queued (default) | 240 | **0** |

30% against 0. Load alone does not do it — the default arm was run on its own
pair of cores at the same oversubscription and never wedged. What the previous
session read as load-sensitivity was arm-sensitivity.

## What the wedged children actually were

Three captures, and a fourth read of the watchdog's own state out of a live
wedge:

- **Three threads alive**: the main thread frozen in the suspend handler
  (`platform/linux_stw.cr:298`, `sigsuspend`), the collector inside
  `run_collection`, and `SYSMON` spinning at the closed monitor gate. **Zero
  worker threads** — all four had exited.
- `Verdict::done`, the harness's completion count, read **3**, **3** and **1**
  of 4 across three children with no workers left to raise it.
- Watchdog state read out of two wedged children: `phase=4` (roots),
  `reported=0`, `started=1`. Armed, running, and reporting nothing because no
  single phase ever stalls: sampled three times 15 s apart, the collector is in
  a *different* place in `scan_all_fiber_roots` / `sweep` each time. The
  collections complete. They just never stop coming.

That is the whole mechanism. `Thread.new` stores a worker's exception and
re-raises it at `join`; it prints nothing on its own. `Verdict.finish` sat
*after* the round loop, so a worker that died never counted. Both waiters —
the collector's `until Verdict.finished >= WORKERS` and the main thread's poll
loop — then wait forever on a number that cannot arrive, the collector keeps
stopping the world, and the child sits at ~100% CPU with every mutator frozen,
no output, no fault, and nothing for the watchdog to say.

**A hang with no output was a dead thread with no funeral.**

## What killed the workers — two different exceptions

### 1. `IndexError` in `guard_release` — fixed here

`GCRY_UNMAP_GUARD=1`'s ledger claimed its slot like this:

```crystal
if @guard_count >= UNMAP_GUARD_SLOTS   # read once, to test
  ...
i = @guard_count                       # read again, to index with
```

Every writer is a mutator inside `GC.free` → `trim_large_cache` →
`guard_release`, and none of them holds a lock. Two frees racing between those
two reads index slot `UNMAP_GUARD_SLOTS` — `IndexError`, raised inside a worker
thread, stored until a `join` that never comes.

The claim is now one atomic read-modify-write (`@guard_slot.add(1)`), the ring
arm's cursor likewise (`@guard_ring`), and the length column is written **last**
and zeroed when the knob is armed: `guarded_release_at` tests
`addr < base + len`, so a slot another thread is still filling matches nothing
and a concurrent SEGV report steps over it instead of naming a half-written
region. `@guard_overflows` is atomic for the same reason.

### 2. `ArgumentError: GC.free: not a live gcry allocation` — narrowed, not closed

With the guard's own race gone, the control arm stops raising — and the arm the
gate calls "queued (default)" starts reporting something that was always there:

```
Unhandled exception: GC.free: not a live gcry allocation (ArgumentError)
  from src/gcry/gc_override.cr:1084:7 in 'free'
  from bench/dormant_flush_race.cr:154:11 in '->'
```

A worker frees the 40 KiB block it allocated four lines earlier, whose payload
it has just verified byte-for-byte, and `is_heap_ptr` → `chunk_containing`
answers that no live chunk holds it. `in_heap_span?` still says yes, which is
why this is an `ArgumentError` and not a SEGV.

`Collector#release_note` (this session) makes the refusal say which of the
three possible reasons applies, because none of them is guessable from the
symptom. On the one instrumented hit so far:

```
bounds [0x7f2412c98000, 0x7f2445c5c000), span [0x7f241249a000, 0x7f2445c9c000),
100 indexed chunks; in bounds: true; on @chunks: no; second lookup: still nil
— no release on record
```

Every branch is answered: the bounds are **not** the problem, the index did
**not** lose an entry the list still had, the lookup is **not** racing, and the
guard — which every release path passes through — never recorded a release.
Off the list *and* out of the index *and* not released is one specific state
with one owner: a chunk a mutator detached in `trim_large_cache` and queued for
the collector, which sits off both structures and still mapped until
`flush_pending_large_release` runs. A probe of that queue and of the
large-cache buckets is now in `release_note`; the next hit either names the
window or refutes it.

Note that the trim only ever detaches chunks that are already **on the large
cache**, which a live block's chunk has no business being on — so if the queue
probe confirms it, the defect upstream of it is a lost root: the sweep took a
live large block for dead, cached its chunk, and the trim then detached it.
That is the family of `2026-08-26-registers-were-never-roots` and
`2026-08-27-signal-frame-below-sp`, reached from a new direction.

What is measured about it:

| condition | children | refusals |
|---|---:|---:|
| `GCRY_MOSTLY_EMPTY=1`, one child at a time, idle box | 424 | 3 |
| the same, run by the gate | 12 | 2 |
| **without** `GCRY_MOSTLY_EMPTY=1` | 80 | **0** |
| six children pinned to two cores | 96 | 0 |

So: **5 of 436 ≈ 1.2%**, and it needs `GCRY_MOSTLY_EMPTY=1` — a knob
`docs/ACIKTURKIYE.md` lists under *Don't bother (measured)*: research opt-in,
never a process default. It also needs **real parallelism**; pinning to two
cores suppresses it, the exact opposite of the control-arm hang above. One
reproducer wanted the squeeze, the other wants the room.

Two of those five landed in the same six-child gate run, minutes from loops of
200 that produced none. At 1.2% that cluster is a one-in-a-thousand draw, so
either it is a very unlucky sample or the rate moves with something not
identified here. Worth remembering before anyone reads a future 0-of-N as a
fix: this needs a few hundred children per arm to say anything.

**The probe fired the same day** (`../2026-08-29-oom-hangs-not-raises/`, last
section): `the chunk is on the collector's release queue, detached and not yet
unmapped — base 0x7fa9e9a60000, 585728 bytes queued in total`. The window is
the one named above, and the defect upstream of it is a lost root — the trim
only detaches chunks that are already on the large cache, which a chunk holding
a live block has no business being on.

The gate's arm labels deserve a word: the arm called "queued (default)" runs
`GCRY_MOSTLY_EMPTY=1 GCRY_UNMAP_GUARD=1`. It is the default *trim* path, not a
default configuration, and nothing measured here says anything about a stock
build.

## Measured

Six children at a time on two cores — a much harsher arm than the gate, which
runs its attempts one at a time:

| binary | hangs | non-zero exits | what the failures say |
|---|---:|---:|---|
| before (control arm) | 20 of 66 | — | nothing at all |
| `+ ensure` (harness counts a dead worker) | **0 of 48** | 18 | 16 × `IndexError` in `guard_release` |
| `+ atomic guard ledger` | **0 of 48** | 1 | the control's own SEGV |

The last row's single fault is contention, not a weakened control: run serially
the way the gate runs it, the control arm faults **6 of 6** with real
`in a chunk gcry RELEASED` reports.

`make spec` 169, `make spec-process` 27, `make page-release-corruption` green
(0 of 4 on all three arms), formatter and knob gate clean.

## What the gate does now

Two `make dormant-flush-race` runs after the change: one **red** — queued arm 2
of 6, every failure the `ArgumentError` above — and one **green**, queued 0 of
6. The gate is now intermittently red *for a stated reason*, where before it
was green whenever the same defect happened to present as a killed child.
Neither run hung, in either arm. Nothing about the collector got worse today: a
failure that used to be a dead thread and a wedged process now arrives as a
named exception with a backtrace, which is the only form of it anyone can act
on.

How often it goes red is the rate question above — 5 of 436 overall, but two of
those five inside one six-child arm. A green gate run is not evidence.

The concession in `5726688` — a hung control child scores as neither fault nor
pass — should stay until defect 2 is closed, but its stated reason is now
wrong: the control-arm hangs were not "the control faulting in a way we cannot
score", they were the guard's own bookkeeping race.

## Method notes worth keeping

- The watchdog only measures **time in one phase**. A collector that completes
  collection after collection forever is invisible to it by construction, and
  "the watchdog printed nothing" must never again be read as "the world is not
  stopped". Read `Gcry::StwWatchdog::phase` / `reported` out of the wedged
  process instead — both are plain BSS symbols and `gdb -batch -ex printf`
  gets them in one line.
- Sample a wedge **more than once**. One backtrace inside
  `scan_all_fiber_roots` looks like a stuck scan; three of them, 15 s apart and
  in three different frames, say the opposite.
- Read the harness's own counters before theorising about the collector.
  `Verdict::done` reading 3 of 4 with no worker threads alive ended a hunt that
  four hours of lock-ordering inspection had not.
