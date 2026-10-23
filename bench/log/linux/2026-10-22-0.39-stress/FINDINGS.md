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

## Round 2, on `07cc4a7f` (2026-10-22)

The same script on `07cc4a7f`: round 1 plus the mprotect re-arm fix, the
frozen-class gaps, the slow-path wipe before its guard-page clamp, and
regression 84's spec fix (`summary-round2.txt`). Every gcry gate passed: 0
failures and 0 stalls in every loop. stw-mt release: 292 of 300, 8 runs the
Crystal scheduler deadlock (one capture kept,
`round2-stw-mt-release-sched-seed235426305.log.gz`), against 6 the night
before. The clamp and the Windows split that came after (`395023e9`,
`e460d60d`) ran their own checks (regression 86's guard-page arms, process_spec
on three layouts, the Windows runners), not this set.

## The final tree, `61f66d7a` (2026-10-23)

The same script on `61f66d7a`, which adds the wipe's guard-page clamp and the
Windows slow-path split to round 2 (`summary-final.txt`; the regression 81
spec change after it, `de79dd4e`, touches no source). Every gcry gate passed:
0 failures and 0 stalls in every loop. Four runs were the Crystal scheduler
deadlock: 3 of 300 in stw-mt release, 1 of 200 in stw-mt debug (one capture
kept, `final-stw-mt-property-test-release-sched-205-seed1063833854.log.gz`).

## Round 3, on `b888ac96` (2026-10-24)

The same script on `b888ac96`: round 3's mark batch loop, the slow-path wipe
on every target, the atomic shared counters, Darwin's executable lookup and
regression 81's rewrite (`summary-round3.txt`). Every gcry gate passed but one
run: 0 failures; Crystal scheduler deadlocks 3 of 300 in stw-mt release and 1
of 200 in stw-mt debug (`round3-stw-mt-debug-sched-seed961788382.log.gz`: the
mark helpers parked in `mark_wait`, workers in `Scheduler#resume`, no
collector or allocation-entry frame in any thread). The debug arm read 0 on
the 0.37.0, 0.38.0 and round-1 nights and 1 on each round-2 and round-3 night.

**One stall: `make chunk-list-drift`, 1 of 6 runs**
(`round3-chunk-list-drift-stall-seed958138121.log`; gdb could not attach,
ptrace scope). It was the gate's own fast arm, the pre-fix shape it keeps on
purpose to show the drift: with `sweep_mutator_latch = false` the flush's
refusal path can link a queued chunk back in front of `@chunks` while the list
already reaches it through the queue, closing a cycle the next walk spins on.
The shipped code (latch on) cannot form it; the pre-round-3 tree hangs the
same way under load. The harness had no deadline for that child. It now runs
every child under one, consents to ptrace, and has an arm that forces the
cycle (`../2026-10-23-drift-stall/`).
