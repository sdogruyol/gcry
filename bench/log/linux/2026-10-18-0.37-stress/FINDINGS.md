# Overnight stress of 0.37.0

`release-0.37.0` at `4b625c87`. Since then the code changed in two places:
the Monitor gate (one line in `collect_stw.cr`, `7a167ddf`) and specs 75, 76
and 77. Linux x86_64 (QEMU guest, 12 vCPUs), Crystal 1.21.0 unless noted.
Every run held a host-wide lock, so nothing else ran beside it, and each was
bounded. Seeds were fresh per run (`$RANDOM`). Harnesses that run a Parallel
execution context went through `bench/run_bounded.sh` (90 s). It captures
every thread on a stall and classifies Crystal's Parallel-scheduler deadlock
(crystal-lang/crystal#17486, reproduced under Boehm with no GC calls in
`../2026-09-25-parallel-scheduler-deadlock/`) apart from a gcry failure.
Script: `stress037.sh`; per-loop counts: `summary.txt`.

| loop | runs | gcry failures |
|---|---:|---:|
| `fuzz`, 60 s each | 30 | 0 |
| `property_test`, 100 000 iterations | 20 | 0 |
| `mt_property_test`, 500 iterations, 2/4/8 workers | 100 | 0 |
| `stw_mt_property_test`, 200 iterations, 2/4/8 workers | 200 | 0 |
| same, `--release`, 400 iterations | 300 | 0 (6 stalls, all the scheduler deadlock) |
| same, header layout + freelist, 2/4 workers | 150 | 0 |
| `pattern_fuzz`, 200 phases × 5 000 objects | 30 | 0 |
| same, header layout + freelist | 30 | 0 |
| `thread_storm --release`, 2 000 × 16 workers | 200 | 0 |
| `make parallel-mark-process` | 20 | 0 |
| `make parallel-mark-termination` | 6 | 0 |
| `make mark-audit` | 6 | 0 |
| `make chunk-list-drift` | 6 | 0 |
| `make large-cache-race` | 10 | 0 |
| `make counter-loss` | 10 | 0 |
| `make realloc-move-stress` | 6 | 0 |
| `make thread-churn-uaf` | 4 | 0 |
| `make soak-smoke` | 6 | 0 |
| `make soft-soak-ec4-smoke` | 4 | 0 |
| `crystal spec -Dgc_none process_spec` | 4 | 0 |
| same, `GCRY_DEBUG_INVARIANTS=1` | 2 | 0 (2 spec failures, below) |
| same, header layout + freelist | 2 | 0 |
| same, Crystal 1.22.0 | 2 | 0 |

1 148 bounded runs, about 3.5 hours. `parallel-mark-termination` and
`mark-audit` are fast (3 s and 2 s a run); a separate run of each showed
their red arms red and green arms green, so they ran what they gate.

## The invariant-checker failures were the spec, not the collector

Both runs of `process_spec` under `GCRY_DEBUG_INVARIANTS=1` failed one
example: spec 75's control arm (`invariants-control-arm.log`). That arm turns
off the fix on purpose, so the frozen mapper drops chunks from the list and
the counters drift. The checker, inherited by the child from the
environment, caught exactly that (`live_objects mismatch: actual=2
reported=211`) and aborted the child, as it should. Spec 75 now unsets the
checker for the control arm only; the fixed arm keeps it. Under the checker
the spec fails 1 of 4 before and passes 4 of 4 after (`73a58553`).

## The stalls are Crystal's scheduler

All six stalls of the release `stw_mt_property_test` were classified from
their captures as the Parallel-scheduler resume deadlock: both workers in
`Scheduler#resume` (`parallel/scheduler.cr:97`), the mark helpers parked, no
collection in progress. `scheduler-deadlock-capture.log` is one of them. The
same harness stalled the same way on 0.36.0 (`../2026-10-15-0.36-stress/`).
