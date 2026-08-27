# The scan stopped at the suspended SP, and the signal frame is below it

2026-08-27, Linux x86_64. **Fixed**, and measured at a sample size that took
four withdrawn readings to learn to use.

## The defect

`stack_scan_low` clamped a suspended thread's stack scan to `SP − 128` (the x86
red zone), where `SP` is what `sp_from_ucontext` reports — the stack pointer the
thread had when the suspend signal arrived.

The kernel writes the signal frame *below* that SP. That frame carries the
interrupted register file, and the part of it gcry never looks at is the FP/SSE
area: `each_thread_greg` walks `uc_mcontext.gregs`, which is general-purpose
registers only. A pointer that LLVM spilled into an XMM register therefore lived
in exactly the region the scan refused to read, and the object it pointed at was
collected.

The repair is to keep a bounded window below the reported SP:

    STACK_SCAN_RED_ZONE + suspended_sp_slack     (4096 bytes, default)

`GCRY_SUSPENDED_SP_SLACK=0` restores the old bound.

## The measurement, and why it had to be done this way

`bench/dormant_flush_race.cr` holds a 40,000-element array in a local and reads
it back at the end; when the object is collected the read comes back `0`.

Three earlier readings of this same defect were single runs per arm and every
one of them was wrong — the loss looked deterministic because six children in a
row lost it, and the same binary later kept it six times in a row. It is
stochastic, like everything else in this family. So: interleaved child by child,
**one binary**, the switch flipped at runtime, because rebuilding moves where
the compiler keeps the value and a two-build A/B measures the compiler.

    slack 4096 (the fix)     0 objects lost of 285
    slack 0 (the old bound) 11 objects lost of 288

One-sided Fisher p = 0.0019.

## What it does not fix

The `0x18` crash. A *full* guard→bottom scan of every running fiber — strictly
more than this fix does — was measured against the clamped scan on that crash,
interleaved, 144 per arm under the unmap guard:

    full scan     7 segv of 144, 0x18 in 7
    clamped       9 segv of 144, 0x18 in 9

No difference. So `0x18` is not a stack-root coverage defect, and that is now
established rather than assumed: static roots, the register capture, the SP
clamp, and the whole running-fiber stack have each been ruled out by
measurement.

## Cost on the real app

Widening every suspended-thread scan by 4 KiB is not free by construction, so
the default was checked against the app before being left on. acikturkiye, wrk,
half an hour each, same machine:

    with the slack (default)   2,447,604 requests, 1359.71 req/s, heap 129 MB, 7371 collections
    without it (prior tree)    2,358,927 requests, 1310.45 req/s, heap 137 MB, 7082 collections

Alive at the end of both, `0 gcry: SIGSEGV` lines in both, and no socket read or
write errors. Two half-hour runs on a loaded workstation cannot resolve a few
percent of throughput in either direction and no claim is made about the
difference — what they establish is that the wider scan does not run the heap
away and does not take the server down.
