# Overnight stress of release-0.38.0 (Linux, 2026-10-20/21)

QEMU x86-64 guest, 12 vCPUs, Crystal 1.21.0, under the host-wide lock.
`stress038.sh` builds every harness from the tree and runs each run bounded
by `bench/run_bounded.sh` (0 pass, 1 fail, 2 stall with a capture, 3 the known
Crystal Parallel-scheduler deadlock, crystal-lang/crystal#17486). `night.sh`
and `night2.sh` are the drivers; `summary.txt` is the stress log.

On `8b9e7eab` (the claim and the scan_stack and frame fixes in, the in-stop
dormancy fix not yet):

| gate | runs | pass | fail | scheduler deadlock |
|---|---:|---:|---:|---:|
| claim_stress, lazy sweep, 4 workers, 5 s, release | 200 | 200 | 0 | 0 |
| claim_stress, sweep in the stop, 4 workers, 5 s, release | 100 | 99 | **1** | 0 |
| claim_stress, sweep in the stop, 2 workers, 2 s, debug | 50 | 50 | 0 | 0 |
| claim_stress, `GCRY_DEBUG_INVARIANTS=1`, 3 s, debug | 30 | 30 | 0 | 0 |
| stw_mt_property_test, 200 iterations, workers 2,4, release, poisoned frees | 300 | 298 | 0 | 2 |
| mt_property_test, 500 iterations, workers 2,4,8, built `-Dgc_none` (the process heap; `make mt-property-test` builds it without, the library-heap arm, which `stress038-full.sh` runs) | 50 | 50 | 0 | 0 |
| thread_storm, 1000 iterations, 10 workers | 30 | 30 | 0 | 0 |
| nursery_tlab_smoke (header layout, freelist) | 1000 | 1000 | 0 | 0 |
| fork_reinit | 50 | 50 | 0 | 0 |
| soak, 2 h | 1 | 1 | 0 | 0 |

**The one failure was a real bug, in 0.37.0 too, and is fixed.**
`claim-instop-1038.log.gz`: live objects drifted by −1632 and free bytes by
+130 560, one chunk of 80-byte blocks. An in-stop sweep made a chunk dormant
while a thread it froze was between checking that chunk free to take and
taking it; the thread then allocated into a dormant chunk, whose pages every
flush releases. Root cause, regression 80 and rates in
`../2026-10-21-claim-counter-drift/`; the fix is `69bd6a2e`. On the fixed tree
(`8eecf233`) the same arm ran 300 of 300 clean (seeds 2001–2300), after the
fix agent's own 200 in-stop and 100 lazy.

**The two stalls** (`stw-mt-1215.log.gz`, `stw-mt-1271.log.gz`) are the
scheduler deadlock as `run_bounded.sh` classifies it: workers spinning in
`Scheduler#resume` and the mark helpers parked in `mark_wait`, no collection
in flight. 0.37.0's stress had 6 in 300 of the same release arm
(`../2026-10-18-0.37-stress/`).

**Soak:** 7200 s, start RSS 4616 kB, end 4496 kB, 7198 collections over
7.2 M allocations, 715 650 finalizable objects and 71 940 weak refs; `# result: PASS`
(`soak-2h.log`).

## The 0.37.0 stress set on the tree that ships (`8c7004b4`), 2026-10-21

`stress038-full.sh` is `../2026-10-18-0.37-stress/stress037.sh` with two
claim arms added (`claim_stress --seconds=5 --workers=4`, release, through
`run_bounded.sh`), run on `8c7004b4` (the dormancy fix in) so the record
compares with 0.37.0's line for line: `full-summary.txt`,
`full-failures.log`.

| gate | 0.38.0 | 0.37.0 |
|---|---|---|
| fuzz 60 s / property-test / mt-property-test | 0/30, 0/20, 0/100 failed | 0/30, 0/20, 0/100 |
| stw-mt, debug | 200/200 | 200/200 |
| stw-mt, release, 400 iterations | 295/300, 5 scheduler deadlocks | 294/300, 6 |
| stw-mt, header layout + freelist | **1/150 failed** (see below) | 0/150 |
| pattern-fuzz, both layouts | 0/30, 0/30 | 0/30, 0/30 |
| claim_stress, lazy sweep | 200/200 | — |
| claim_stress, sweep in the stop | 300/300 | — |
| thread-storm release, the make gates (parallel mark ×2, mark-audit, chunk-list-drift, large-cache-race, counter-loss, realloc-move-stress, thread-churn-uaf, soak-smoke, soft-soak-ec4-smoke) | 0 failed | 0 failed |
| process_spec ×4, invariants ×2, headers+freelist ×2, Crystal 1.22 ×2 | 0 failed | invariants 2/2 failed (spec 75's control arm under the checker, a spec bug fixed before 0.37.0 shipped), the rest 0 |

**The header-layout freelist failure was a hang, not an error.** Seed
22868 printed its banner and nothing else; the arm took 1287 s against
0.37.0's 98 s, so that one run sat until `timeout 1200` killed it. That loop
does not go through `run_bounded.sh`, so there is no capture of it. The same
binary rerun 200 times through `run_bounded.sh` (20 at seed 22868, 180 at
random seeds): 199 passed, seed 22868 20 of 20, and one stalled
(`hdr-freelist-rerun-sched-seed10507.log.gz`) in the scheduler deadlock's
shape — threads spinning in `Scheduler#resume` (`parallel/scheduler.cr:97`),
the six mark helpers parked in `mark_wait`, no collection in flight. The
original hang is most likely the same deadlock [INFERENCE: it has no
capture].
