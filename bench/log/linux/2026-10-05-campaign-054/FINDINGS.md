# Campaign 054 — 6 h on `5cc3ab4`

Linux x64, 5 lanes, 2026-10-04 23:32 – 2026-10-05 05:32 UTC, binaries built
from a worktree of `5cc3ab4` with the Makefile's flags: campaign-053's tree
(`0671a0c`, the mark with no type layout) plus the nursery gate's research
property (`Heap#nursery_old_scan`, default on) and the Darwin/Windows
register scrub, which this Linux campaign does not run. Same lanes and runner
as 049-053.

| lane | runs | nonzero |
|---|---:|---:|
| churn (`thread_churn_uaf`) | 907 | 0 |
| churn_hdr | 907 | 0 |
| dormant_flush (`GCRY_TRACE_LARGE=1`) | 907 | 0 |
| index_grow | 907 | 0 |
| pattern_fuzz+diag | 907 | 0 |
| stw_mt | 907 | 0 |
| stw_mt+diag (two seed ranges) | 1 814 | 5 |
| stw_mt+pm4 | 907 | 0 |
| stw_mt_hdr_tlab | 907 | 0 |
| stw_mt_hdr_tlab_nursery | 907 | 1 |
| thread_storm | 907 | 0 |
| thread_storm+pm4 | 906 | 0 |
| **total** | **11 790** | **6** |

All six are 300 s timeouts with crystal-lang/crystal#17486's shape — two
threads at `fiber/execution_context/parallel/scheduler.cr:97`, no collector
frame, no fault report — seeds 20048, 20150, 20424, 20429, 20709 and 20724.
Not counted against gcry.

No gcry fault in 11 790 runs; with campaign-053, 23 363 runs on the
layout-free mark.
