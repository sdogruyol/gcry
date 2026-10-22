# Overnight stress of release-0.39.0 (Linux, 2026-10-22)

`bench/stress_overnight.sh` on `6609ac8e` (the in-stop audit with its review
fixes; before the regression 80 spec rework and the steal gate's extra
collections, which change no source), QEMU x86-64, 12 vCPUs, Crystal 1.21.0,
every run through `bench/run_bounded.sh` under the host-wide lock:
`summary.txt`, about 3.5 hours.

| gate | 0.39.0 | 0.38.0 (`../2026-10-21-0.38-stress/full-summary.txt`) |
|---|---|---|
| fuzz 60 s / property-test / mt-property-test | 30/30, 20/20, 100/100 | the same |
| stw-mt, debug | 200/200 | 200/200 |
| stw-mt, release, 400 iterations | 294/300, 6 scheduler deadlocks | 295/300, 5 |
| stw-mt, header layout + freelist | **150/150**, every run bounded | 149/150, one uncaptured hang |
| pattern-fuzz, both layouts | 30/30, 30/30 | the same |
| claim_stress lazy / in-stop | 200/200, 300/300 | the same |
| thread-storm release, 11 make gates (now with `make claim-stress`) | all pass | all pass |
| process_spec ×4, invariants ×2, headers+freelist ×2, Crystal 1.22 ×2 | all pass | all pass |

The six stalls are the Crystal Parallel-scheduler deadlock as
`run_bounded.sh` classifies it (crystal-lang/crystal#17486; one capture kept,
`stw-mt-release-sched-seed976683491.log.gz`), the same rate as 0.37.0's and
0.38.0's nights.

`header-arms-summary.txt` is a separate run on the audit branch before its
review fixes (`869063bd`), for regression 84's
freelist changes: the header layout with the freelist allocator, lazy and
in-stop, debug and release, and with TLAB and nursery, 1 030 bounded runs,
0 gcry failures, 1 scheduler deadlock. It does not set `GCRY_ALLOC_BATCH`,
so it says nothing about the two review findings on 84; their arms are in
regression 84 (`../2026-10-22-in-stop-sweep-audit/`).
