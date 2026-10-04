# Campaign 053 — 6 h on `0671a0c`, the mark with no type layout

Linux x64, 5 lanes, 2026-10-04 17:29 – 23:29 UTC, binaries built from a
worktree of `0671a0c` (`mark: read no type layout`) with the Makefile's
flags. Same runner and lanes as campaigns 049-051. Everything after it on
master that night is findings, docs, gates and the Darwin/Windows register
scrub, none of which this Linux campaign runs.

| lane | runs | nonzero |
|---|---:|---:|
| churn (`thread_churn_uaf`) | 890 | 0 |
| churn_hdr | 890 | 0 |
| dormant_flush (`GCRY_TRACE_LARGE=1`) | 890 | 0 |
| index_grow | 890 | 0 |
| pattern_fuzz+diag | 890 | 0 |
| stw_mt | 891 | 0 |
| stw_mt+diag (two seed ranges) | 1 782 | 3 |
| stw_mt+pm4 | 890 | 1 |
| stw_mt_hdr_tlab | 890 | 0 |
| stw_mt_hdr_tlab_nursery | 890 | 1 |
| thread_storm | 890 | 0 |
| thread_storm+pm4 | 890 | 0 |
| **total** | **11 573** | **5** |

All five are 300 s timeouts with crystal-lang/crystal#17486's shape — two
threads at `fiber/execution_context/parallel/scheduler.cr:97`, no collector
frame, no fault report — seeds 20139, 20151, 20441, 20685 and 20800
(`night/`). Not counted against gcry.

No gcry fault in 11 573 runs.

Campaign 052 ran the same lanes on `6f8ff0c` (the `Hash`-only intermediate)
and was stopped after 751 runs, 0 nonzero, once that tree was shown to have
its own collision (`../2026-10-04-layout-union-collision/`).
