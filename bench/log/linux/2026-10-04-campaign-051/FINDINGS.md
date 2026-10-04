# Campaign 051 — 6 h on `955827a`, the 0.34.0 candidate

Linux x64, 5 lanes, 2026-10-04 04:48 – 10:50 UTC, `--debug` binaries from a
worktree of `955827a`: everything in 0.34.0's product code — the batched large
trim, the heap-span prefilter and inlined lookups, the Monitor's sleeping wait,
the threshold cap that follows the scanned bytes, the parallel-mark sharing
fixes, the helpers' idle backoff and `GCRY_PARALLEL_MARK_MIN_LIVE`. Same lanes
and runner as campaign-049, with the churn lanes built from
`bench/thread_churn_uaf.cr` from the start.

| lane | runs | nonzero |
|---|---:|---:|
| churn (`thread_churn_uaf`) | 700 | 0 |
| churn_hdr | 700 | 0 |
| dormant_flush (`GCRY_TRACE_LARGE=1`) | 700 | 0 |
| index_grow | 700 | 0 |
| pattern_fuzz+diag | 700 | 0 |
| stw_mt | 700 | 0 |
| stw_mt+diag (two seed ranges) | 1 400 | 3 |
| stw_mt+pm4 | 699 | 1 |
| stw_mt_hdr_tlab | 700 | 2 |
| stw_mt_hdr_tlab_nursery | 700 | 0 |
| thread_storm | 699 | 0 |
| thread_storm+pm4 | 699 | 0 |
| **total** | **9 097** | **6** |

All six are 300 s timeouts with crystal-lang/crystal#17486's shape — two
threads at `fiber/execution_context/parallel/scheduler.cr:97`, no collector
frame, no fault report — in seeds 20035, 20068, 20095, 20406, 20464 and 20587
(`night/`). Not counted against gcry. 6 in 4 199 `stw_mt`-family runs (0.14%).

No gcry fault in 9 097 runs. With campaigns 049 (12 804 runs) and 050 (3 834
runs with mark helpers), 25 735 runs over the changes 0.34.0 carries.
