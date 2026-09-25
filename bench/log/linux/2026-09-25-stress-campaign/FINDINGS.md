# A day of varied-seed stress: 20 lane-hours, one live-object bug found and fixed

**Date:** 2026-09-25 · host: Linux 7.0.0-31-generic x86_64 (QEMU, 12 vCPU),
Crystal 1.21.0 · orchestrator `run.py` beside this file · raw rows
`results-4a7c16a.tsv` (before the fix) and `results-84fba65.tsv` (after)

Nightly CI fuzzes only the library heap, 30 minutes, fixed seed 42. The
process GC under multi-threaded stress with *varied* seeds had never been run
for hours. This did: four or five lanes pulling (harness, seed) pairs
round-robin with fresh seeds from 1000, every harness from the repo's own
gates, each run bounded by a timeout.

| harness | what it is |
|---|---|
| `stw_mt` / `stw_mt+diag` | `stw_mt_property_test`, process GC, 2/4/8 Parallel workers, default layout; `+diag` adds `GCRY_POISON_FREED=1 GCRY_SEGV_REPORT=1` |
| `stw_mt_hdr_tlab` / `_nursery` | the same on the header layout, freelist allocator, TLAB (and nursery) — opt-in configurations |
| `pattern_fuzz` / `+diag` | process GC allocation-pattern fuzzer, 200 phases × 5000 objects |
| `mt_prop`, `prop`, `layout_prop` | the library-heap property tests |
| `fuzz` | the library-heap fuzzer, 300 s per seed (the nightly job's harness) |
| `thread_storm` | 1000 × 10 thread births against the process GC |

## Before the fix (tree `4a7c16a`): 673 runs, 8.44 lane-hours

| harness | runs | failed | lane-hours |
|---|---|---|---|
| fuzz | 59 | 0 | 4.92 |
| pattern_fuzz+diag | 61 | 0 | 1.97 |
| pattern_fuzz | 61 | 0 | 0.81 |
| stw_mt / +diag | 62 / 62 | 0 / 0 | 0.29 |
| **stw_mt_hdr_tlab** | **62** | **2** | 0.11 |
| stw_mt_hdr_tlab_nursery | 62 | 0 | 0.14 |
| mt_prop, prop, layout_prop, thread_storm | 61 each | 0 | 0.19 |

Both failures: pinned live objects reported DEAD together, one chunk
(seed 1010: roots 3–15 after collection #71; seed 1054: roots 3+ after #44).
Logs beside this file. Root cause: the chunk index grew with `realloc` under a
stopped-world reader — `../2026-09-25-index-grow-realloc/FINDINGS.md`. The
rate under this load (2 of 62) is far above a quiet host's (~1 in 900): more
preemption, more chances to be frozen in the window.

## After the fix (tree `84fba65`): 1047 runs, 11.64 lane-hours

TLAB arm weighted ×3, five lanes, fresh seeds.

| harness | runs | failed | lane-hours |
|---|---|---|---|
| fuzz | 80 | 0 | 6.67 |
| pattern_fuzz+diag | 80 | 0 | 2.49 |
| pattern_fuzz | 81 | 0 | 1.04 |
| stw_mt | 81 | 0 | 0.18 |
| **stw_mt+diag** | **81** | **1 timeout** | 0.43 |
| **stw_mt_hdr_tlab** | **243** | **0** | 0.41 |
| stw_mt_hdr_tlab_nursery | 81 | 0 | 0.18 |
| mt_prop, prop, layout_prop, thread_storm | 80 each | 0 | 0.24 |

**The TLAB arm: 0 of 243 after, 2 of 62 before.** At the pre-fix rate the
chance of 243 clean runs is under 0.1%.

**One stall, not explained yet.** `stw_mt+diag` seed 1032 (default layout)
printed the start of its first arm and nothing else for 900 s
(`stw_mt_diag-1032-timeout.log`); no watchdog was armed, so it left no phase.
The same seed and env were clean 12 of 12 afterwards. One probe that stalled
past 60 s showed the thread-group leader as a zombie — a process whose main
thread had exited while others ran on — but was not captured before it
ended. A hunter that dumps every thread's state and a backtrace through a live
thread on a 60 s stall is running (`hunt_hang.sh` beside this file);
its result is appended below.

## Total

1720 runs, 20.08 lane-hours, over two trees. For the ROADMAP's "documented
fuzz hours": 11.6 h of the library fuzzer and 20 h across the process-GC and
library harnesses in all.
