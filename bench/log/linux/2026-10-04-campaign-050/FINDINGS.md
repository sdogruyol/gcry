# Campaign 050 — 7 h of parallel mark on `84d696a`

Linux x64, 3 lanes, 2026-10-04 01:45 – 08:45 UTC, `--debug` binaries from a
worktree of `84d696a`: the three parallel-mark sharing fixes (`08a7eeb` push
buffers, `2f9c916` radix counters, `aaf1433` `mark_noscan` without the lock)
and the master's termination peek. Not the idle backoff or the live-set floor,
which came later and are in campaign-051. Every lane runs with mark helpers.

| lane | runs | nonzero |
|---|---:|---:|
| stw_mt+pm4 | 548 | 2 |
| stw_mt+pm4+diag | 548 | 0 |
| stw_mt+pm2 | 547 | 3 |
| stw_mt_hdr+pm4 (`-Dgcry_block_headers`) | 548 | 2 |
| thread_storm+pm4 | 548 | 0 |
| pattern_fuzz+pm4 (+diag) | 548 | 0 |
| churn+pm4 (`thread_churn_uaf`, poison holders, unmap guard) | 547 | 0 |
| **total** | **3 834** | **7** |

All seven are 300 s timeouts with crystal-lang/crystal#17486's shape: two
threads at `fiber/execution_context/parallel/scheduler.cr:97`, no collector
frame, the mark helpers asleep in their idle loop. 7 in 2 739 `stw_mt`-family
runs (0.26%), against 0.37% in campaign-048 with one marker — the helpers do
not move the rate.

No lost mark, fault or poisoned read in 3 834 runs with two or four mark
workers, on both layouts, including the `Hash`-heavy `pattern_fuzz` and the
thread-churn lane whose holders are poisoned on free.
