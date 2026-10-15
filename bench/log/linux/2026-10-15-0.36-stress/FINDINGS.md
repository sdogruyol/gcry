# Overnight stress of 0.36.0

`release-0.36.0` at `48e7c74` (the code of the final integration; later
commits are documentation). Linux x86_64, 12 vCPUs, Crystal 1.21.0. Every run
held a host-wide lock, so no other job ran beside it, and each was bounded at
1 200 s. Seeds are fresh per run (`$RANDOM`). Scripts: `stress.sh` (round 1),
`stress3.sh` (round 3), `hang_loop.sh`.

| loop | runs | failed |
|---|---:|---:|
| `fuzz`, 30 s each | 40 | 0 |
| `fuzz`, 60 s each | 30 | 0 |
| `property_test`, 100 000 iterations | 20 | 0 |
| `mt_property_test`, 500 iterations, 2/4/8 workers | 220 | 0 |
| `stw_mt_property_test`, 200 iterations, 2/4/8 workers | 30 | 0 |
| same, round 2 | 400 | 1 hang (below) |
| same, `--release`, 400 iterations | 150 | 4 hangs (below) |
| same, header layout + freelist, 2/4 workers | 200 | 0 |
| `pattern_fuzz`, 200 phases × 5 000 objects | 50 | 0 |
| `thread_storm`, 1 000 × 10 workers | 320 | 0 |
| `thread_storm --release`, 2 000 × 16 workers | 300 | 0 |
| `make realloc-move-stress` | 10 | 0 |
| `make chunk-list-drift` | 6 | 0 |
| `make large-cache-race` | 10 | 0 |
| `make counter-loss` | 10 | 0 |
| `make thread-churn-uaf` | 4 | 0 |
| `make soak-smoke` | 6 | 0 |
| `make soft-soak-ec4-smoke` | 4 | 0 |
| `crystal spec -Dgc_none process_spec` | 6 | 0 |
| same, `GCRY_DEBUG_INVARIANTS=1` | 3 | 0 |
| same, `-Dgcry_block_headers`, `GCRY_BITMAP_ALLOC=0` | 3 | 0 |

1 822 bounded runs in the table, plus about 133 release runs of round 2 before
it was stopped; 50 minutes of `fuzz` alone, about four hours of wall time in
all.

## The hangs are Crystal's Parallel scheduler

`stw_mt_property_test` runs its allocators in a
`Fiber::ExecutionContext::Parallel`. Round 2 hung 1 of 400 debug runs and 4
of the first ~133 release runs at the 1 200 s bound, each right after
printing a worker phase header (`round2-timeouts.log`). `hang_loop.sh` then
ran the release binary 150 times through `bench/run_bounded.sh`, 60 s bound,
which captures every thread on a stall and classifies it: 146 passed, 0
failed, and 4 stalls, all four classified as the Crystal 1.21
Parallel-scheduler deadlock (crystal-lang/crystal#17486, reproduced under
Boehm with no GC calls in `../2026-09-25-parallel-scheduler-deadlock/`).
The five round-2 timeouts were not captured; they stopped at the same point
the classified stalls did. `scheduler-deadlock-capture.log` is one capture: both `stw-mt` workers in
`Scheduler#resume` (`parallel/scheduler.cr:97`), the mark helpers parked in
`wait_for_mark_epoch`, no collection in progress. The header-layout loop ran
under the same classifier and stalled in none of its 200 runs.
