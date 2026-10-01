# Stress campaign-044 on `c752cdb` (2026-10-01)

Campaign-041's jobs plus two lanes with `GCRY_PARALLEL_MARK=4`, five lanes for
five hours. The tree had the parallel-mark fixes of the day and the Darwin
`start_world` fix.

**3 932 runs, 25.1 lane-hours, 0 failures, 4 timeouts.**

| lane | runs | failed | timed out |
|---|---:|---:|---:|
| `churn_hdr` | 302 | 0 | 0 |
| `churn` | 302 | 0 | 0 |
| `dormant_flush` | 302 | 0 | 0 |
| `index_grow` | 302 | 0 | 0 |
| `pattern_fuzz+diag` | 303 | 0 | 1 |
| `stw_mt+diag` | 606 | 0 | 0 |
| `stw_mt+pm4` | 302 | 0 | 2 |
| `stw_mt_hdr_tlab_nursery` | 303 | 0 | 0 |
| `stw_mt_hdr_tlab` | 303 | 0 | 0 |
| `stw_mt` | 303 | 0 | 1 |
| `thread_storm+pm4` | 302 | 0 | 0 |
| `thread_storm` | 302 | 0 | 0 |

Three timeouts have the upstream shape: `stw_mt` seed 20136 and `stw_mt+pm4`
seeds 20197 and 20210. Each has two threads at `parallel/scheduler.cr:97`,
no collector frame and no STW report (crystal-lang/crystal#17486).

**One is gcry's.** `pattern_fuzz+diag` seed 20149 ran 900 s single-threaded,
in the Stride phase, with the main thread in
`GC.free` → `free_owned?` → `trim_large_cache` → `unlink_chunk`
(heap.cr:2804, the predecessor walk). That is the stack of the campaign-036
sighting (seed 20102). `unlink_chunk`'s walk has been bounded since then and
did not report, so no single walk ran past twice the index. The same seed
passed locally at full length. `trim_large_cache`'s detach walk over the
buckets is now bounded and reports as well. Two later sightings, captured
with `info locals`, showed it is not a cycle. Freeing a large object costs
O(live large chunks), and retention had pushed the index to 29 000–50 000
(`../2026-10-01-large-free-quadratic/`).
