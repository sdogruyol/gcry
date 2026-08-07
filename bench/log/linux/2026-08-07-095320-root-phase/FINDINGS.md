# Intermediate cut — stack path fixed, pthread path not yet

Kept as the isolation point: this run has the low-water skip on the parked-fiber
scan only, before it was applied to `scan_pthread_stack`. That shows in the
breakdown — `roots` had collapsed (312 ms → 19.9 ms against the `-nolw` control)
while `stacks` had not (794 µs tuned → 9678 µs sound).

Superseded by `2026-08-07-110231-root-phase/`, which has both paths and the full
A/B. Do not compare the two runs' absolute numbers: `tuned` pause was 18.0 ms
here and 7.1 ms there, so only within-run comparisons mean anything.
