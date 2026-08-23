# A live large object is released under load — acikturkiye, 2026-08-23

Found while taking a gcry-vs-Boehm cut on the fat app: the gcry binary dies
under `wrk` in roughly one run in eight. Not a benchmark artefact — a
use-after-free.

    Invalid memory access (signal 11) at address 0x…
      << at char.cr:1032
      to_json at json/builder.cr:134
      call at kemal/route_handler.cr:164
      handle_client at http/server/request_processor.cr:58
      run at fiber.cr:168

A request fiber is writing JSON and the memory under it is gone.

## What it is

`GCRY_UNMAP_GUARD=1` (added for this) releases a chunk with
`mprotect(PROT_NONE)` instead of `munmap` and keeps its identity, so the
SIGSEGV report can describe what was released instead of saying it is gone.
Two independent sightings, same shape:

    in a chunk gcry RELEASED — base 0x7fb7075c1000, 69632 bytes,
      large-object release, at collection 89; the write is 34343 bytes into it

    in a chunk gcry RELEASED — base 0x7fb1d3b7e000, 69632 bytes,
      large-object release, at collection 13; the write is 28672 bytes into it

So: a **69 632-byte large-object chunk** — a ~64 KiB buffer — released by the
**large-object path** while a fiber is writing tens of kilobytes into it. The
response is 36 KB and `LARGE_THRESHOLD` is 32 KiB, so this is the JSON response
buffer after it outgrows the size classes and becomes a large object with its
own chunk. A live object was collected.

Note what the size means for a *smaller* buffer: a size-class block would be
freed and reused rather than unmapped, so the same bug would corrupt silently
instead of faulting. The crash is the loud end of this, not the whole of it.

## What has been ruled out, and how

| reading | verdict | by what |
|---------|---------|---------|
| empty size-class chunk release | no | `GCRY_KEEP_CHUNKS=1` still died 1 of 12 |
| large objects allocated unmarked during a collection | no | `alloc_large` sets the mark on both paths when `@collecting` — read, not measured |
| a `noscan` layout field drops its target | no | `mark_noscan_unlocked` calls `heap_set_mark`; it declines to *scan* the target, not to mark it |
| `MADV_DONTNEED` page release | no | on anonymous memory that returns zero pages, it cannot fault |
| an interior pointer the tuned profile rejects | no | `GCRY_INTERIOR=1`: 1 of 16 against a guarded baseline of 3 of 16 |
| **a heap object points at it and the mark missed the edge** | **no** | `GCRY_MARK_AUDIT=1` reported **0 edges** in the run that crashed |

## Where that leaves it

No heap object holds the buffer when it dies, and the mark's own completeness
audit agrees — so the mark was never the problem, which is what pointed at the
allocator's own bookkeeping and found the asymmetry above.

### The rate collapsed, and that is the first thing to fix next time

| arm | crashed | when |
|-----|--------:|------|
| baseline, before any change (guarded) | 7 of 60 | early session |
| lock fix | 0 of 24 | later |
| faithful control, sequential | 1 of 24 | later |
| **interleaved, `-c 100`** | **control 0 of 14, fixed 0 of 14** | later still |
| **interleaved, `-c 250`** | **control 0 of 16, fixed 0 of 16** | last |

The control arm restores the old behaviour and should reproduce the 11.7%
baseline. It does not — it produces nothing, at either concurrency, with the
arms interleaved so machine drift cannot favour one. So the defect's rate moved
by an order of magnitude for a reason that is not the knob, some time between
the early runs and the later ones, and every comparison since is measuring
noise against noise.

Two candidates, neither tested: the machine (load moved between 2 and 13 across
the day, in both directions), and the several rebuilds of both gcry and the app
in between. Until that is settled no arm here means anything, which is why
**re-establishing the baseline on the current tree is step one for the next
session** — before testing any hypothesis, confirm the crash still happens at a
rate this harness can resolve.

What was tried to raise it: a heavier endpoint (none exists — `/api/v1/` at
36 192 B is the largest, and every other route is far below the 32 KiB
threshold so it never produces a large object at all), and higher concurrency
(`-c 250`, no effect). `LARGE_THRESHOLD` is a compile-time constant with no
knob; adding one would raise the rate but would also change size-class
behaviour across the board, i.e. change what is being measured.

**Open**: whether that asymmetry is the whole of it. The rate is now low enough
that this harness cannot resolve it; the next session needs either a much
longer batch or a workload that hits the large cache harder, and it should
start by re-establishing the baseline on the current tree before testing
anything.

Also tried and reverted, because the measurement did not support it: rooting
`realloc`'s new block across the copy (2 of 24, indistinguishable from
baseline). The window is not inside `realloc`.

## Reproducing

    cd ../acikturkiye && ACIKTURKIYE_ENV=demo crystal build -Dgc_none --release \
      src/acikturkiye.cr -o bin/acikturkiye-gcry
    GCRY_UNMAP_GUARD=1 GCRY_SEGV_REPORT=1 ./bin/acikturkiye-gcry &
    wrk -c 100 -d 20 -H "X-API-KEY: …" -H "X-API-SECRET: …" http://127.0.0.1:3000/api/v1/

Roughly one run in eight without the guard, three in sixteen with it.

## Three harness lessons, because each one nearly produced a wrong answer

- **A stale server on the port turned every run into `Address already in use`,**
  which the harness counted as a crash: 12 of 12 in two arms, both meaningless,
  and `wrk` was measuring the *stale* process the whole time. A run is only
  counted now if the pid listening on the port is the one it started, and a
  death only counts when the log shows a fault.
- **One log per arm meant the next trial overwrote the crash.** Per-run logs now.
- **`pkill -f acikturkiye-` matches the script's own command line** and kills the
  run. Kill by pid from `/proc/*/exe` instead.
