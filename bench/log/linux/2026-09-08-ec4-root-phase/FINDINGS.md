# Where the EC4 pause goes: the parked-fiber lag scan

Date: 2026-09-08 · host: AMD Ryzen AI 9 465, Linux 7.2.2 · tree `a04ebdc`
Kemal `/json`, `wrk -t4 -c100 -d15`, `GCRY_ROOT_PHASE_TIMING=1`, `/gc-stats`
sampled every 0.4 s under load, medians of the last-collection phase timers.
`rootphase.py` and `samples.txt` beside this file.

## Question

`../2026-09-08-heuristics-ab/` measured the tuned EC4 pause at p50 12.6 ms
with 12.3 ms in `phase_roots` — 3.5× the 3.60 ms of 2026-08-09. Which root
sub-phase, and why.

## Result (ms, median of last-collection timers)

| arm | pause p50 | roots | of which fibers | threads | stacks | mark | sweep | collections / 15 s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| EC1 | 0.84 | 0.25 | 0.22 | 0.03 | 0.02 | 0.39 | 0.03 | 557 |
| **EC4** | **9.21** | **8.60** | **8.43** | 0.15 | 0.19 | 0.58 | 0.55 | 266 |
| EC4, `GCRY_SOUND=1` | 60.8 | 77.0 | 76.9 | 0.12 | 2.53 | 0.54 | 0.34 | 155 |
| EC4, `GCRY_STW_STACK_LAG=65536` | — | 6.97 | 6.79 | 0.15 | 0.20 | 0.55 | 0.72 | 347 |
| EC4, `GCRY_STACK_LOW_WATER=0` | — | 15.7 | 15.5 | 0.15 | 0.45 | 0.54 | 0.67 | 263 |

## What it says

1. **It is `roots_fibers_ns`, all of it**: 8.43 of the 8.60 ms root phase,
   98%. Threads, cursors, metadata, static, stacks are all under 0.25 ms.
   Mark and sweep are unchanged from EC1.
2. **The mechanism is the multi-mutator lag window** (`collect_scan.cr`
   `fiber_scan_start`, `stw_multi` branch). On EC1 a parked fiber is scanned
   from its saved `stack_top` up to `bottom` — its live frames, a few KiB.
   Under multi-mutator STW every parked fiber is scanned from
   `max(stack_top − lag, low_water)` instead, because a fiber mid-swap onto
   another thread can have a stale `stack_top`. With ~100 connection fibers
   that is up to 25 MB of stack words per collection; the pagemap low-water
   skip rescued 17.4 MB of it (71 fibers), the rest — ~8 MB, pages a
   previous, deeper use of the same pooled stack had already faulted in —
   was scanned at ~1 GB/s. Confirmations: no low-water skip → 15.5 ms
   (the full window); lag 64 KiB → 6.8 ms, not 4× less, because the touched
   depth below SP is already near 64 KiB on most of these stacks.
3. **`GCRY_SOUND=1` is the same scan without the lag bound**: lag 0 means
   from the guard page, 636 MB skipped by pagemap per collection, 77 ms for
   what remains. That is the "large pause cost where the root scan is big"
   README warns about, now with the number attached.
4. Why 3.6 ms on 2026-08-09 and 8.4 ms now: the volume is `parked fibers ×
   min(lag, faulted depth below SP)`. Faulted depth grows with stack-pool
   reuse — every fiber that once ran deep leaves those pages present for the
   next tenant, and the low-water skip can no longer see through them. A
   fresh process with fresh stacks pays less; a server that has been up pays
   the full window. The earlier cut was closer to the former.

## What would fix it (roadmap, not this session)

The lag exists for one reason: a parked fiber's `stack_top` may be stale
while the fiber is in transit between threads. A fiber the scheduler has
fully parked (in a wait queue, owned by no thread) has a trustworthy
`stack_top`, and could be scanned from it as on EC1; only fibers in transit
need the lag. That is the same root-coverage audit of the Parallel scheduler
the roadmap already carries (Phase 2, "Audit root coverage for the EC
Parallel scheduler"), with a pause number to justify it: ~8 ms of a 9 ms
pause at EC4, growing with uptime. A per-fiber high-water mark recorded at
swap time would do the same job as the pagemap skip without the reuse
blind spot, and without the `pread`.
