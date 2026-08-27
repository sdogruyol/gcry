# The captured registers were all zero, so a register was never a root

2026-08-26, Linux x86_64. **Fixed**, with the capture proven to work afterwards.
Whether it closes any of the open crashes is measured separately below, and the
answer so far is no.

## What was wrong

`Platform.record_thread_sp` copies a suspended thread's GP registers out of its
`ucontext` into a table the mark later walks through `each_thread_greg`. It did
it like this:

    @@stw_gregs[slot][i] = (uctx + UCONTEXT_GREGS_OFFSET + i * 8).as(UInt64*).value

`@@stw_gregs` is a `StaticArray(StaticArray(UInt64, 32), 64)`, and `StaticArray`
is a **value type**: the inner subscript hands back a *copy* of the row, the
assignment lands in that copy, and the copy is dropped on the next line. The
table was never written.

So `each_thread_greg` fed the mark 23 zero words per thread, and reported 23
words while doing it — the count came from `@@stw_ngregs`, which *was* written.
Every check that asked "is this value in a suspended thread's registers?"
answered "no" without ever having looked at one.

The SP was right the whole time, which is why nothing noticed: it comes from
`sp_from_ucontext`, read straight out of the `ucontext` and never through this
table.

## How it was found

Not by reading the code. `GCRY_DYING_GREG_DUMP=1` prints every captured word for
every thread at the moment a live object is about to be swept:

    gcry:   gregs of thread 0x7f723db93780: 0x0 0x0 0x0 … (23 zeros)
    gcry:   gregs of thread 0x7f723cdff6c0: (none)
    gcry:   gregs of thread 0x7f7239b9e6c0: 0x0 0x0 0x0 … (23 zeros)

Four threads reporting registers, every word zero in all four. After the fix,
the same dump on the same bench:

    gcry:   gregs of thread 0x7fb2aebd9780: 0xa 0x0 0x0 0x246 0x7ffdac0e1f50
            0x7ffdac0e2050 0x7fb2aeb4d028 0x7fb2a77ff6c0 0x55b1a97280d4 …

Stack addresses, heap addresses, a return address — a register set.

## What it does not fix

The deterministic loss in `../2026-08-26-debug-build-own-stack-root/` is
unchanged: `ballast 0` before the fix and `ballast 0` after it, on the same
binary shape. So the object that dies there is not held in a register either,
and this repair — real as it is — is not that defect's cause.

That is worth stating in its own line, because the temptation after finding a
bug this clean is to assume it explains the thing you were chasing.

## It does not move the `0x18` rate

Measured properly, which took two attempts.

The first attempt compared two *builds* — 4 of 72 against 3 of 72 — and that is
not a comparison: the binaries differed by more than the fix, and in this bench
a rebuild moves where the compiler keeps values (see the sibling file). So
`GCRY_DISABLE_GREG_ROOTS=1` was added: one binary, the register-marking loop
skipped at runtime, interleaved child by child under the guard arm.

The first 96 per arm read 3 against 6 and looked like the fix halving the rate.
Extended to 288 per arm, it does not:

    registers as roots on     14 segv of 288, 0x18 in 14
    registers as roots off    10 segv of 288, 0x18 in 10

Engagement: `greg_total` ~8,000 words per child in the on arm and exactly 0 in
the off arm, so both arms are what they claim to be. Fisher on 14/288 against
10/288 is p ≈ 0.5 — no effect in either direction, and the encouraging 3-vs-6
was noise that would have been reported as a result if the run had stopped
there.

So the ledger for today is: one real defect found and repaired, and it buys
nothing against either open crash.

## A second hole, still open

With thread names attached to the dump:

    "DEFAULT-0":               23 real words
    "SYSMON":                  (none)   — never signalled, by design
    (unnamed):                 (none)   — **unexplained**
    (unnamed) ×3:              23 real words
    (the collecting thread):   (none)   — no ucontext, expected

Seven threads, five of them suspended, four with registers. One suspended
thread's registers are missing on every collection this was looked at.

Checked and ruled out:

- **The handler not running.** `handler_calls 2807` against `records 2801`, and
  `sp_zero 0` — every handler call that ran also recorded, and none was skipped
  for a zero SP.
- **A thread published during the stop.** `staged_waits 1, staged_timeouts 0`
  in 70 of 72 children: the wait for a staged thread fires once per run and
  never gives up, so the world is never stopped around an unpublished thread
  here.
- **The clear racing the record.** `clear_thread_sps` does run *after* the
  resume loop, which looks like a window — but a new collection cannot send
  suspend signals until this one releases `Thread.unlock`, which is later still.

So the thread is listed, suspended, and has no registers, and none of the three
obvious mechanisms accounts for it. It is a smaller question than the crashes
this file came from and it is written down here so it is not rediscovered.

## It does not regress the real app

The fix widens the root set, so the thing to check is that it does not cost
throughput or retain the heap. acikturkiye on the fixed tree, wrk, half an hour:

    2,358,927 requests in 30.00m, 1310.45 req/s
    alive, collections 7082, heap 137 MB
    0 `gcry: SIGSEGV` lines, 0 socket read/write errors

Against the same app on the tree before the fix — 1383 req/s over an hour, heap
134 MB — that is the same shape. Two runs of different lengths on a loaded
workstation cannot resolve a few percent of throughput, and no claim is made
about that; what they do show is that turning ~59,000 register words per run
into roots did not run the heap away or take the server down.
