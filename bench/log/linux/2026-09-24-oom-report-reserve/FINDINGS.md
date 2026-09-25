# Running out of memory ended in SIGSEGV instead of `OutOfMemoryError`

**Date:** 2026-09-24 · host: Linux 7.0.0-31-generic x86_64 (QEMU, 12 vCPU),
Crystal 1.21.0 · `bench/oom_no_hang.cr`, probe `bin/probe_ec/p.cr` (gitignored)

Probe: `RLIMIT_AS` 1.5 GiB; three fibers on a
`Fiber::ExecutionContext::Parallel` each loop on `Bytes.new(4096)`, and in the
`rescue` drop what they held and report on a channel.

## Two layers

**1. The message was built before the guard.** gdb on the crash:
`alloc_old_small → oom!("failed to refill size class #{payload}") →
String::Builder → malloc(80) → alloc_old_small → …` until the fiber's stack
overflowed. The argument is interpolated by the *caller*, before `oom!` runs
and sets its recursion flag, so the flag never covered the one allocation it
was for. Every interpolated message had the same shape (heap.cr ×4, tlab.cr ×5).
`oom!` now takes a literal and the number, and builds the text inside.

| build (probe `p.cr`) | outcome, 5 runs |
|---|---|
| 0.27.1 | 5 × SIGSEGV |
| message built inside `oom!` | 5 × exit 1, `Unhandled exception: out of memory (nested raise …)` |
| same, `GCRY_OOM_EAGER_MESSAGE=1` (the old interpolation) | 5 × SIGSEGV |

That exit 1 turned out to be the probe, not the collector: its main fiber
built `"worker #{n}: …"` while the workers still held the heap. With every
string it prints prebuilt (`p2.cr`) the message fix alone was clean in 256
of 257 runs; the remaining one was a SIGSEGV that printed nothing.

**2. The report needs memory the heap may not have.** The message, the
`OutOfMemoryError`, Crystal's `CallStack` and the `LibUnwind::Exception`
`raise` allocates on every raise all come from the heap at the moment it has
nothing left. Whether that fails depends on which size classes happen to be
dry, which is why the unforced rate is low and not zero. When it fails, the
nested path raises the prebuilt `@oom_error`, and that raise's own
`LibUnwind::Exception` fails too: recursion again.

## The fix: a reserve

`src/gcry/oom_reserve.cr`. 4 MiB of anonymous memory mapped at boot and not
touched (address space and commit charge, no RSS). A thread inside `oom!`
(per-thread depth, `@@oom_depth`) allocates from a cursor set of its own that
takes only chunks laid on that region (`ChunkHeader::Flags::RESERVE`), with no
syscall, so neither `RLIMIT_AS` nor the commit limit can refuse it at the
moment. Ordinary cursors never take those chunks (`bitmap_pool_candidate?`)
and the sweep never releases them (`sweep_small_bitmap`). The objects in them
are ordinary scanned and collectable objects; the chunks stay for the next
report.

Depth 2, where the prebuilt error's raise itself could not allocate, now
prints `gcry: out of memory while reporting out of memory; aborting` and
aborts, instead of recursing until the stack overflows.

## Making it deterministic

`GCRY_OOM_TEST_EXHAUSTED=1` (research only): once one allocation has failed,
every small allocation the reserve does not serve fails too. The report's
allocations then fail on every run, whatever is left in their classes.
`make oom-no-hang`'s parallel arm runs under it:

| arm | exit | time | output |
|---|---|---|---|
| shipped | 0 | 1.4 s | three reports with their own messages (`failed to refill size class 4096`, `… 32`, `… 4096`); reserve served 18 blocks |
| `GCRY_OOM_RESERVE_KB=0` | 134 (SIGABRT) | 6.4 s | the abort line, twice |
| `GCRY_OOM_EAGER_MESSAGE=1` | 139 (SIGSEGV) | 7.7 s | nothing (stack overflow) |

`make oom-no-hang` three times in a row: shipped 3/3 clean each time, both red
arms 3/3 each time. The large and small arms are unchanged and green.

Probe `p2.cr` on the reserve build, no knob: 20/20 clean.

## Spec

`spec/oom_reserve_spec.cr`, both halves red-proven by removing the line:

- without the sweep's `|| ChunkHeader.reserve?(chunk)`, an emptied reserve
  chunk is unmapped after its grace and the probe for it finds no chunk;
- without the `reserve?` test in `bitmap_pool_candidate?`, ordinary
  allocations land in the reserve's range.

## Limits

- Bitmap allocator without a nursery (the default on both layouts). Under
  `GCRY_NURSERY` or the freelist allocator there is no reserve; the message
  fix and the depth-2 abort still apply.
- A report is served by the reporting thread's own cursor first when it has a
  free block; the reserve is taken only when that cursor refills.
- The reserve's current chunks are pinned through each stop-the-world, as the
  shared fallback set's are, so their garbage is reclaimed once the cursor
  moves on: one chunk per class held at most.
- Raw `Thread.new` crashes on out-of-memory under every gcry version since
  0.26.0 and under Boehm alike, without any limit set; `Thread` is `:nodoc:`
  in Crystal 1.21. Only the supported execution contexts are tested.
