# Campaign 049 — 8 h on `d78371f`

Linux x64, 5 lanes, 2026-10-03 20:45 – 2026-10-04 04:45 UTC, binaries built
with `--debug` from a worktree of `d78371f`. That tree has the batched large
trim, the heap-span prefilter, the inlined layout lookup, the Monitor's
sleeping wait, the master's termination peek and the threshold cap that
follows a third of the scanned bytes; it does not have the 2026-10-04
parallel-mark fixes. Same runner as campaign-048 (`run-049.py`; gdb
`thread apply all bt` and `info locals` on a stall).

| lane | runs | nonzero |
|---|---:|---:|
| churn (`thread_churn_uaf`) | 882 | 0 |
| churn_hdr | 882 | 0 |
| dormant_flush (`GCRY_TRACE_LARGE=1`) | 1 003 | 0 |
| index_grow | 1 004 | 0 |
| pattern_fuzz+diag | 1 004 | 0 |
| stw_mt | 1 004 | 0 |
| stw_mt+diag (two seed ranges) | 2 008 | 3 |
| stw_mt+pm4 | 1 003 | 0 |
| stw_mt_hdr_tlab | 1 004 | 1 |
| stw_mt_hdr_tlab_nursery | 1 004 | 0 |
| thread_storm | 1 003 | 0 |
| thread_storm+pm4 | 1 003 | 0 |
| **total** | **12 804** | **4** |

The two churn lanes were built from `bench/churn.cr` by mistake for their
first 244 runs, which all failed at once on the `--child` argument that only
`bench/thread_churn_uaf.cr` takes; they were rebuilt from that file 1 h into
the run (`NOTES.txt`) and those 244 are not counted above.

## The four

| lane | seed | log |
|---|---:|---|
| stw_mt+diag | 20534 | `night/stw_mt+diag-20534-4.log` |
| stw_mt+diag | 20614 | `night/stw_mt+diag-20614-0.log` |
| stw_mt+diag | 20699 | `night/stw_mt+diag-20699-0.log` |
| stw_mt_hdr_tlab | 20807 | `night/stw_mt_hdr_tlab-20807-0.log` |

All four are 300 s timeouts with crystal-lang/crystal#17486's shape: two
threads at `fiber/execution_context/parallel/scheduler.cr:97`, no collector
frame anywhere; the only gcry frames are the STW watchdog and the idle
collector asleep in their loops. Not counted against gcry. 4 in 4 017
`stw_mt`-family runs (0.10%), against 6 in 1 603 (0.37%) in campaign-048.

## The rest

No gcry fault in 12 804 runs. `dormant_flush` with `GCRY_TRACE_LARGE=1`
armed: 1 003 more runs without the 2026-09-28 large-release sighting, about
4 400 since. `pattern_fuzz` ran 1 004 times on a build *with* the batched large
trim (`c12ac5e`, `568cd1d`) and never stalled. Its Stride phase used to stall
for 900 s in about one run in 300–1 200; at that rate zero in 1 004 happens
in 3.5–43% of campaigns this size, so this is support for the fix, not proof.

The parallel-mark changes of 2026-10-04 (`08a7eeb`, `2f9c916`, `aaf1433`) are
in campaign-050 instead.
