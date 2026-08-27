# gcry stops scanning the main thread's stack 8 KiB below its base

2026-08-26, Linux x86_64. **Open.**

> **The word "deterministic" appeared throughout this file and it was wrong.**
> It came from a run of six children that all lost the object, then several
> more, on one binary. Run again later, the *same* binary keeps the object six
> times in a row. The loss is stochastic like everything else in this family,
> and every single-run A/B recorded below — the scan-window knob, the full-stack
> switch, the SP slack sweep — is therefore unsupported. They are left in place
> because the mistake is the useful part: a low-rate event sampled once per arm
> reads as a clean result, and this is the third time in this session that shape
> produced a finding that had to be withdrawn.

## What happens

`bench/dormant_flush_race.cr` holds its 40,000-element ballast array in a local
in `main` and reads it again at the end. Built two ways from the same source,
same machine, same load:

    crystal build --release                        ballast 40000   (6 of 6)
    crystal build --release --debug                ballast     0   (5 of 5)
    crystal build --release --link-flags -no-pie   ballast 40000   (6 of 6)

`--debug` is the flag. `-no-pie` is not.

The array is not replaced and nothing removes elements. Printing its address
alongside its size says what actually happened:

    child: ballast built 40000 at 0x7fa42e93ed98
    child: ballast before join 0 at 0x7fa42e93ed98
    child: ballast 0 at 0x7fa42e93ed98

Same object, and its `@size` field went to zero underneath a local that still
points at it. The block was handed out again.

## Who says so

`GCRY_THREAD_BLOCK_AUDIT=1 GCRY_DYING_TYPE_ID=49` (`Array(Bytes)` in this
binary) fires in **8 of 8** children, at **collection 0**:

    gcry: dying-type audit — block 0x7ff85957ed98 size 32 type_id 49 is
    unmarked and about to be swept. In a suspended thread's registers: no
    (of 115 words). Offered by the collecting thread's own stack scan: no.

The reported addresses all end in `d98` — the same block the trace above names,
so this is the ballast and not a same-shaped piece of garbage.

Collection 0 happens while the ballast is still being built, so the thread that
triggers it is `main` — the thread whose own frame holds the reference. The
audit's verdict is therefore about gcry's scan of **its own caller's stack**,
and that scan does not offer a pointer the caller is holding.

`bench/spin_local_root.cr` reduces the shape — main holds an array, spins, a
second thread collects — and reports `intact`. So the frame shape alone is not
enough; what `--debug` changes about where the value sits is.

## Why it matters beyond one bench

The oldest open crash in this tree is `stop_world` faulting at `0x18` because
`Thread::LinkedList`'s `@mutex` reads null, and the block behind it is swept
unmarked in every child that crashes (16 of 16 across two batches of 144,
`../2026-08-23-zeroed-object-0x18/FINDINGS.md`). That is the same defect —
something live is not reached by the mark — measured at a few percent instead
of deterministically. If the cause here is the own-stack scan, that crash is one
instance of it rather than a defect of its own.

The immediate practical reading is narrower and worth stating plainly: **a
program built with `--debug` can have live objects collected.** That is not a
debugging aid failing, it is the collector failing, and `--debug` is what most
people build with while they are diagnosing something.

## Not yet established

Which part of the scan loses it. The candidates are the `setjmp` in
`scan_mutator` being taken after gcry's own frames have overwritten the
callee-saved register that held the value (`src/gcry/birth_grace.cr:35` already
records this as an open question), and the own-stack scan's bounds.

## The block is the ballast, exactly

Address printed by the bench and address named by the audit, same run:

    child: ballast built 40000 at 0x7fa22d274d98
    gcry: dying-type audit — block 0x7fa22d274d98 ... unmarked and about to be swept
    child: ballast 0 at 0x7fa22d274d98

Not a same-shaped piece of garbage: the same block, before and after.

Two readings taken along the way that do **not** support this, and are recorded
so nobody re-derives them:

- The first `d98`-suffix "match" across different runs proved nothing. Every
  block of that size class ends at that offset in its chunk.
- A `push_stack` counter added to measure how many thread stacks the mark
  receives read `stacks_min 0, stacks_max 0` — because `push_stack` is the
  *parked fiber* path and is never called here. It was removed rather than
  left in place reading zero.

## Where it is not

- **Static roots.** `static_min == static_max` in every one of 144 children
  (516096 or 520192 bytes), so the globals are scanned in full, every
  collection. A class-variable canary in the same children was never damaged.
- **The BSS range going missing from the `/proc/self/maps` re-parse.** Counted
  directly: `bss_lost 0` across 144 children, and the parse never came back
  smaller than the best it had seen (`root_shrinks 0`).
- **The collecting thread's own stack window.** Never empty or inverted
  (`win_empty 0`). Its widest span differs between the two builds — 6984 bytes
  with `--debug`, 14624 without — which is frame size, not a broken bound.

## The remaining lead

`scan_all_fiber_roots` decides how much of a *running* fiber's stack to scan
from

    stw_multi = @world_stopped && multi_mutator_threads?

and falls back to "the cheap `stack_top` clamp" otherwise. A running fiber's
`@context.stack_top` is only written on a context switch, so for a main fiber
that has never switched it is stale by construction, and a clamp against it
scans a window that has nothing to do with where that thread's frames are. That
is the shape the two builds differ by: `--debug` makes `main`'s frame big enough
to sit outside the window that the plain build's frame fits inside.

`multi_mutator_threads?` reads the same thread list whose object this tree's
other open crash is about, which is worth stating plainly: if that list is ever
short, root coverage narrows, and narrowed coverage is what kills the list.

## The stale-`stack_top` lead did not survive either

`fiber_stack_scan_top` falls back to a running fiber's `@context.stack_top`
only when no SP was recorded for it. Counted:

    fib_sp 3194, fib_guard 955, fib_stale 0

Never. Every running fiber's stack is scanned from a recorded SP or from the
guard page, so the window is not the wrong one.

And the loss survives the most conservative root policy gcry has —
`GCRY_SOUND=1`, which accepts interior pointers, accepts unaligned candidates,
turns the `type_id` gate off, and scans parked stacks in full:

    GCRY_SOUND=1   ballast 0
    GCRY_SOUND=0   ballast 0

So no root heuristic is discarding it. The reference is not in any place gcry
looks — not the globals, not any stack window, not the suspended registers.
What is left to test is whether it is anywhere at all at that moment: the
address-space audit finds 17 words holding the base, and it cannot say which
regions they are in because it had `0 thread bounds` to compare against. Naming
those 17 is the next instrument, and it is a smaller question than any asked
here so far, because the reproducer is deterministic and the block is known by
address before it dies.

## The audit had already answered it

Every `gcry:` line, not the ones grepped for. The address-space audit names each
holder and classifies it:

    0x7f9c0706cd98 held at 0x7fffc122e9d8 in [0x7fffc0234000,0x7fffc1233000)
      rw-p [stack] — running fiber stack, BELOW the scan window
      (scan starts at 0x7fffc1230258, bottom 0x7fffc1231000)

Three holders on the main thread's `[stack]`, and the window the mark used was
`[0x7fffc1230258, 0x7fffc1231000)` — **3496 bytes**, on a 16 MiB stack.

Two numbers in that line matter more than the three holders:

    [stack] VMA ends at   0x7fffc1233000
    the scan stops at     0x7fffc1231000

**8192 bytes short of the stack's base.** The outermost frames of `main` live in
exactly those bytes. The bound comes from `fiber.@stack.bottom` — Crystal's
recorded bottom for the main fiber — and it is not the thread's stack base,
while gcry has the real bounds in hand at the same moment: the audit's own line
says "7 on Crystal's list, **7 of them with snapshotted stack bounds**".

## Boehm keeps the same object

The control that separates "gcry misses a reference" from "the compiler let it
die". Same shape, same `--debug`, Crystal's own collector:

    boehm: ballast built 40000 at 0x7fc7235acfa0
    boehm: ballast 40000 at 0x7fc7235acfa0, seen 40000

So a live reference exists and Boehm finds it — Boehm scans a thread's stack to
its real base. This is not codegen dropping a value; it is a window that ends
too low.

The earlier title of this file said "a live local is collected", which was the
right symptom for the wrong reason: the reason is not `--debug` and not the
frame shape, it is the bound. `--debug` only decides whether the frame holding
the reference lands inside the 3.5 KiB that does get scanned.

## What a fix has to do

Scan a running thread's stack to the bounds gcry already snapshotted with
`pthread_getattr_np`, not to `fiber.@stack.bottom`, whenever the two disagree —
and count the disagreement, because a bound that is right on this host and short
on another is exactly the kind of thing that reads as fixed while it is not.

## A fix was attempted, and it did not work

Extending a running fiber's scan to the thread bounds gcry snapshots with
`pthread_getattr_np` looked like the obvious repair. Two versions, both wrong:

1. Unguarded, it took the bounds of whichever thread's SP fell inside the
   fiber's stack and scanned to them. A fiber running on its own allocated
   stack has a thread whose bounds describe a different mapping entirely, so
   the scan ran off one region into whatever followed another. The child died.
2. Guarded on the pthread mapping containing the fiber's stack
   (`lo <= base && hi >= bottom`), it never fired: `bottom_ext 0` over a full
   run, and the ballast was lost exactly as before.

The second is the more useful failure. It says the assumption underneath the
"what a fix has to do" paragraph above is false: for the main fiber, the
snapshotted pthread bounds do **not** contain `fiber.@stack`'s range. So the two
numbers are not two descriptions of one stack, and the 8 KiB gap is not simply
`fiber.@stack.bottom` being a short version of the pthread base.

Both versions have been backed out rather than left in place. An extension that
never fires reads like a fix in a diff and is worth less than nothing.

The next step is smaller than a fix: print, for the main thread, the pthread
bounds and `fiber.@stack` side by side, and find out what the 8 KiB between
`bottom` and the end of the `[stack]` VMA actually belongs to.

## The 8 KiB gap is not where `main`'s frames are

`bench/main_stack_bounds.cr` prints all three views at once:

    fiber.@stack.pointer 0x7ffe2efe4000
    fiber.@stack.bottom  0x7ffe2ffe2000
    pthread bounds       [0x7ffe2efe4000, 0x7ffe2ffe2000)
    a local in main      0x7ffe2ffe11a0
    maps [stack]         7ffe2ffc3000-7ffe2ffe4000

Two things settle here, and one claim above has to come out:

- `fiber.@stack` and the `pthread_getattr_np` bounds are **identical**. That is
  why the attempted extension never fired, and it closes that avenue for good:
  there is no wider bound for gcry to reach for.
- A local in `main` sits at `0x7ffe2ffe11a0`, **below** `bottom` and therefore
  inside the scanned range. So the 8 KiB between `bottom` and the end of the
  `[stack]` mapping is not where `main`'s frames live — it is the argv / envp /
  auxv block the kernel puts at the top of the stack. **The section above that
  said the outermost frames of `main` live in those bytes is withdrawn.**

So the scan bound is not short in the way this file first claimed, and the
three holders the audit reported in the dying case were all *below* the
suspended SP — dead slots by the ABI, which a collector is right to skip.

What remains, and it is the whole finding now: **Boehm keeps this object and
gcry does not**, on the same source and the same `--debug` build. That is
measured and it is not explained. The next instrument has to name the other 14
of the 18 base hits — the audit prints at most a handful and skipped 11 regions
— because one of them is the reference Boehm follows.

## How far this reaches: the real app under `--debug` survives

The obvious worry — "a `--debug` build can have live objects collected" — needed
a program that is not this bench. acikturkiye, built the same way
(`--release --debug -Dgc_none`), under wrk for half an hour:

    1,378,733 requests in 30.00m, 765.93 req/s
    alive after 30 min, collections 4168, heap 112 MB
    0 `gcry: SIGSEGV` lines

And the same app without `--debug`, for an hour:

    4,979,881 requests in 60.00m, 1383.27 req/s
    alive, collections 14870, heap 134 MB (131 MB at collection 4331)
    0 `gcry: SIGSEGV` lines, 0 socket read/write errors

So the loss is not a property of `--debug` builds in general. What is
established is narrower and still worth having: in one program, deterministically,
gcry collects an object Boehm keeps, and the flag decides it. That is a
reproducer, not a blast radius.

## The register count is not a hole

"In a suspended thread's registers: no (of 115 words)" divides as 5 × 23, and
the audit now says so directly: `115 words from 5 of 7 threads`. The two that
contribute nothing are accounted for and neither is a gap:

- the collecting thread, which has no `ucontext` to read;
- **SYSMON**, Crystal's `ExecutionContext::Monitor`, which `stw_signal_exempt?`
  deliberately never signals — suspending it deadlocks the collector, and
  `MonitorGate` shuts it out instead.

So every thread that *was* suspended had all 23 of its GP registers read,
`main` among them, and the value was in none of them.

## Where this stands

Eliminated, each by measurement: static roots, the BSS range, the collecting
thread's own window, the stale `stack_top` clamp, every root heuristic
(`GCRY_SOUND=1`), a stale suspended SP (the table is cleared at every
`start_world`), the scan bound versus the pthread bounds (identical), and the
register capture (complete for every suspended thread).

Boehm keeps the object across 30,000 rounds per worker — fifteen times the
churn of the first control — so "Boehm simply had not recycled it yet" is out
too.

The defect is characterized and **not fixed**. What is known: a specific block,
by address, unmarked and swept, deterministically, with the flag deciding it,
and no live holder in any region gcry scans. What is not known is what Boehm
follows that gcry does not, and none of the root sources is the answer. The next
question is not about roots at all — it is whether the mark reaches it through
another object, and the instrument for that is a reachability diff against
Boehm rather than another counter inside gcry.

## The reproducer is deterministic inside a binary and not across builds

Worth writing down before anybody spends a day on it as I did. Two arms of a
knob that only widened the scan below a suspended thread's SP:

    GCRY_SUSPENDED_SP_WINDOW=8192   ballast 40000
    GCRY_SUSPENDED_SP_WINDOW=0      ballast 40000

The second arm *is* the old behaviour, so the object survived with the change
switched off. What repaired it was the rebuild: adding a getter to the bench's
report line moved where LLVM keeps the local, and the loss went with it.

So this bench reproduces at 100 % within one binary and disappears on the next
compile of a barely different source. Any A/B run by rebuilding is measuring the
compiler. The knob was backed out for that reason — an unmeasured change to what
the mark scans is not a fix, and this one could not be measured this way.

To A/B anything here the switch has to be runtime-only in a binary built once,
and even then the arm that "works" may just be the arm whose codegen was lucky.

## Second register hole, named

The register dump with thread names attached:

    "DEFAULT-0": <23 real words>
    "SYSMON": (none)             — exempt from suspension by design
    (unnamed): (none)            — a worker, and this one is not explained
    (unnamed) ×3: <23 real words>
    (the collecting thread): (none)  — no ucontext, expected

One suspended worker thread contributes no registers. That is a second hole in
the root set, distinct from SYSMON's, and it is open. It is not the cause of the
ballast loss — that object is `main`'s local and `main` (`DEFAULT-0`) has its
registers read — but it is the same kind of defect as the one fixed in
`../2026-08-26-registers-were-never-roots/`.
