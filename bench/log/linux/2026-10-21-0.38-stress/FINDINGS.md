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
