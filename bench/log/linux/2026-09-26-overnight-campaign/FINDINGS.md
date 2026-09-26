# Overnight stress campaign on 0.27.2: 4 448 runs, 50 lane-hours, 0 failures

**Dates:** 2026-09-25 19:25 → 2026-09-26 05:25 UTC · host: QEMU x86_64,
12 vCPU, 11 GB, Linux 7.0, glibc 2.43, Crystal 1.21.0 · 5 lanes ·
driver `run2.py`, summary `summarize.py`, raw `results.tsv` (all beside this file).

**Tree.** The binaries were built at 16:30 (+0300) on 2026-09-25, one minute
after `84fba65` (the chunk-index growth fix). The only `src/` change between
that and the `v0.27.2` tag is the version string, so this is 0.27.2's
collector. It does **not** include the SYSMON guard-scan fix of 2026-09-26
(`../2026-09-26-sysmon-guard-scan/`); that fix was checked separately with 90
fresh STW property seeds, 60 TLAB+nursery / TLAB-only samples and three
5-hour CI soak arms.

## Lanes

Each lane pulls (job, seed) pairs round-robin until the deadline; seeds start
at 20 000 and do not repeat. Every run is bounded, and one that outlives its
bound gets every thread's state and a gdb backtrace of all threads recorded
before it is killed.

| lane | what | diagnostics |
|---|---|---|
| `stw_mt` | STW property test, default layout, 2/4/8 workers | — |
| `stw_mt+diag` | same, two seed streams | freed-block poison, SEGV report, STW watchdog |
| `stw_mt_hdr_tlab` | header layout, TLAB | — |
| `stw_mt_hdr_tlab_nursery` | header layout, TLAB + nursery | poison, report, watchdog |
| `pattern_fuzz+diag` | 200 phases × 5 000 objects | poison, report, watchdog |
| `churn`, `churn_hdr` | thread churn (the thread-churn-uaf child), both layouts | unmap guard, holders poison, report, watchdog |
| `index_grow` | chunk-index growth with a 50 ms stall injected | poison, report |
| `mt_prop` | library multi-thread property test | — |
| `fuzz` | library fuzzer, 300 s per seed | — |
| `thread_storm` | 1 000 thread births × 10 workers | — |

## Result

| lane | runs | failed | timed out | lane-hours |
|---|---:|---:|---:|---:|
| `churn` | 371 | 0 | 0 | 0.1 |
| `churn_hdr` | 371 | 0 | 0 | 0.1 |
| `fuzz` | 369 | 0 | 0 | 30.8 |
| `index_grow` | 371 | 0 | 0 | 2.4 |
| `mt_prop` | 370 | 0 | 0 | 0.2 |
| `pattern_fuzz+diag` | 371 | 0 | 0 | 11.8 |
| `stw_mt` | 371 | 0 | 2 | 1.0 |
| `stw_mt+diag` | 742 | 0 | 1 | 1.8 |
| `stw_mt_hdr_tlab` | 371 | 0 | 0 | 0.7 |
| `stw_mt_hdr_tlab_nursery` | 371 | 0 | 0 | 0.8 |
| `thread_storm` | 370 | 0 | 0 | 0.4 |
| **total** | **4 448** | **0** | **3** | **50.0** |

**No run failed**: no lost object, no SEGV, no poison hit, no watchdog report,
on any layout or lane.

**The three timeouts are all the Crystal scheduler deadlock**, not the
collector. Each capture (`stall-*.txt`) shows the same thing: the two Parallel
worker threads running (`R`) in `Scheduler#resume` at
`parallel/scheduler.cr:97`, the main thread in `epoll_wait`, no collector frame
anywhere, no collection in progress. Seed 20003 was the first capture and the
one that led to
`../2026-09-25-parallel-scheduler-deadlock/FINDINGS.md`, where the deadlock is
reproduced under Boehm with no GC calls, shown to be a circular wait, and fixed
by an upstream patch (72 stalls in 2 500 runs → 0). 3 in 1 113 default-layout
STW runs (0.3%) is in line with that reproducer's rate on a loaded host.

That also closes the one open stall of the previous campaign
(`../2026-09-25-stress-campaign/`, seed 1032, 900 s, not reproduced in 12
reruns): same test, same shape of hang under load. It could not be classified
then, because that capture had no backtrace. `[INFERENCE]` It is the same deadlock.

## Against the previous campaign

| | 2026-09-25 (0.27.1 → 0.27.2 work) | this one (0.27.2) |
|---|---:|---:|
| runs | 1 720 | 4 448 |
| lane-hours | 20 | 50 |
| collector failures | 2 lost-object runs before the index fix, 0 after | 0 |
| stalls | 1, unclassified | 3, all the upstream scheduler deadlock |
