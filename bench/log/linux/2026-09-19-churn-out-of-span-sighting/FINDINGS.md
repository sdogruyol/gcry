# A churn-gate fault at an address gcry never allocated

2026-09-19, run `35424121362` (the `v0.26.2` tag run), Linux x86_64 job, step
`Live-object release under thread churn`. The same tree's branch run
(`35424119977`, commit `8d79743`) was green in all 20 jobs, so this is a rate,
not a regression introduced by the release.

## What the gate said

    === a live large object released under thread churn ===
    24 attempts per arm, 240 rounds x 8 threads each
    layout: headerless

      default    0 of 24 failed (0.0%)
      reported   0 of 24 failed (0.0%)
      guarded    0 of 24 failed (0.0%)
      poisoned   1 of 24 failed (4.2%)

    poisoned sighting:
      gcry: SIGSEGV at 0x55816aff0 — outside gcry's heap span
      [0x7f2ac4f5f000, 0x7f2ac7641000) — never a gcry allocation, so a swept
      object is not the explanation

## What that line does and does not establish

It establishes three things. The faulting address was **never** in gcry's span,
so it is not a swept object and not a released chunk — the `guarded` arm would
have named the chunk, and it did not fault at all. The collector was **not**
inside the pthread stack-bounds query, which is what selects that third
reading (`segv_report.cr`'s `.no_query?` branch); the two other readings exist
precisely because a fault *inside* that query cannot exclude a swept `Thread`.
And it is not the poison: `GCRY_POISON_FREED` would have put `0xdeadf2ee…` in
the faulting context, and the report says so when it does.

It establishes **nothing about what that address is**, which is the gap. The
report knows the address is in no gcry mapping and stops there. 0x55816aff0 is
not a plausible thread stack (those are `0x7f…` here) and not the poison; it
looks like a low mmap or an image-relative address, and "looks like" is all
this line can support.

## Rate, measured

| where | arm | rate |
|---|---|---|
| CI, 2-core runner, headerless | poisoned | 1 / 24 |
| this host, 20 cores, headerless | poisoned | **0 / 96** |

96 children, same four knobs the arm sets
(`GCRY_UNMAP_GUARD=1 GCRY_SEGV_REPORT=1 GCRY_POISON_HOLDERS=1
GCRY_THREAD_UNSTAGE_ON_DEATH=1`), 240 rounds × 8 threads each. The control arm
still reproduces the defect this gate was built for (5 of 8 here), so the
harness is driving the workload; the shipped arms' zeros are a measurement.

Same shape as this repo's other thread-birth defects: CI-only, and the
observer is the obstacle.

## What is missing, and it is one line of report

`Platform.each_map_region` already walks every mapping with its name,
allocation-free and callable with the world stopped — `address_space_audit.cr`
uses it to name the region holding a dying block. The SEGV report does not use
it for the **faulting address itself**. With it, this sighting would have read
"inside an anonymous rw-p mapping of 16 MiB, 0x1850 below its top" — which is
the signature this repo has already learned to read as a stack — or named the
library the address belongs to. Without it a sighting like this one costs a
rerun and leaves nothing behind.

That is the next piece of work, and it is a report change, not a collector
change.


## Done: the report names the mapping now

`segv_report.cr`'s out-of-span branch flushes its reading and then asks the
kernel. `report_faulting_region` walks `Platform.each_map_region` — raw
syscalls into the walker's own stack buffer, safe on the 256 KiB report
alt-stack — and prints one more line. Measured on this host with a probe that
faults on purpose:

    gcry: SIGSEGV at 0x2a0000001234 — outside gcry's heap span [...] — never a gcry allocation ...
    gcry: that address is in a mapping [0x2a0000000000, 0x2a0000100000) ---p, 1048576 bytes, 0xfedcc below its top, anonymous

    gcry: SIGSEGV at 0x2b0000001234 — outside gcry's heap span [...]
    gcry: that address is in a mapping [0x2b0000000000, 0x2b0000100000) ---p, 1048576 bytes, 0xfedcc below its top, /…/bin/segv_region_report

    gcry: SIGSEGV at 0x300000000000 — outside gcry's heap span [...]
    gcry: no mapping holds that address — it is not in this process's address space at all, so it is a wild pointer rather than a stale one

Its own line and its own buffer: `RawOut::LIMIT` is 480 bytes and the readings
above already run close to it — appending to the same buffer would have been
silently truncated.

`make segv-region-report` gates it with three arms and checks the **numbers**,
not the words: the named range must contain the faulting address, the size must
equal both the range's width and the mapping's own size, the distance below the
top must equal `hi - addr`, a file-backed mapping must be named by path and an
anonymous one as anonymous, and an address in no mapping must be reported as
wild rather than attributed to the nearest region. Removing the one call makes
all three arms fail — observed, 3 of 3.

What this would have given the sighting above: whether `0x55816aff0` was in an
anonymous mapping (and how far below its top, which is the stack signature this
repo already reads), in a library, or in no mapping at all — i.e. stale pointer
versus wild pointer, which are different defects. The next one leaves evidence.

The harness's `Gcry::SegvReport.install` is inside its platform guard and the
file is in `make windows-typecheck`: an unguarded reference to that module in a
harness is what broke six Windows jobs on 2026-09-16.
