# Campaign 048 — 7 h on `c85a35c` (0.33.0 + leaderboard)

Linux x64, 5 lanes, 2026-10-03 13:33–20:33 UTC; binaries built from a worktree
of `c85a35c` (the 0.33.0 release plus the leaderboard commit). Runner:
`~/.cache/campaign-048/run-048.py`, which attaches gdb to a child that outlives
its timeout and records `thread apply all bt` plus `info locals` for frames
0–2.

| lane | runs | nonzero |
|---|---:|---:|
| churn | 401 | 0 |
| churn_hdr | 401 | 0 |
| dormant_flush (`GCRY_TRACE_LARGE=1`) | 400 | 0 |
| index_grow | 401 | 0 |
| pattern_fuzz+diag | 401 | 0 |
| stw_mt | 401 | 2 |
| stw_mt+diag (two seed ranges) | 802 | 2 |
| stw_mt+pm4 (`GCRY_PARALLEL_MARK=4`) | 400 | 2 |
| stw_mt_hdr_tlab | 401 | 0 |
| stw_mt_hdr_tlab_nursery | 401 | 0 |
| thread_storm | 400 | 0 |
| thread_storm+pm4 | 400 | 0 |
| **total** | **5209** | **6** |

## The six

All six are 300 s timeouts in the `stw_mt` family, and all six have the same
shape: two threads at `fiber/execution_context/parallel/scheduler.cr:97`
(`resume` spinning on a fiber another scheduler still runs), the main thread in
`epoll_wait` under `find_next_runnable`, and no collector frame on any thread.
The only gcry frames are threads asleep in their own loops: the STW watchdog's
`watch_loop` (`stw_watchdog.cr:227`), the idle collector's `loop_forever`
(`idle_release.cr:194`) and, in the pm4 lanes, the mark helpers' idle sleep
(`parallel_mark.cr:446`). That is crystal-lang/crystal#17486, Crystal's own
scheduler deadlock, which gcry does not count against itself
(`ci/sound-suite.sh` retries it on the next seed for the same reason).

| lane | seed | log |
|---|---:|---|
| stw_mt+diag | 20103 | `night/stw_mt+diag-20103-4.log` |
| stw_mt+pm4 | 20213 | `night/stw_mt+pm4-20213-2.log` |
| stw_mt | 20217 | `night/stw_mt-20217-2.log` |
| stw_mt+pm4 | 20331 | `night/stw_mt+pm4-20331-1.log` |
| stw_mt | 20388 | `night/stw_mt-20388-2.log` |
| stw_mt+diag | 20388 | `night/stw_mt+diag-20388-3.log` |

Rate: 6 in 1 603 `stw_mt`-family runs (0.37%), spread evenly over the plain,
diagnostic and parallel-mark arms, so neither the diagnostics nor parallel
mark moves it.

## The rest

No gcry fault in 5 209 runs. `dormant_flush` ran 400 times with
`GCRY_TRACE_LARGE=1` armed for the one open large-release sighting
(ROADMAP, 2026-09-28) and did not reproduce it; that brings the lane to about
3 400 runs since.

`pattern_fuzz` ran 401 times without its known Stride-phase stall (O(live
large chunks) per `GC.free`, which stalled about one run in 300–1 200). The
build predates the batched large-object trim (`c12ac5e`, `568cd1d`), so this
says nothing for or against that fix: at the old rate, zero in 401 happens
in between a quarter and three quarters of campaigns this size.
