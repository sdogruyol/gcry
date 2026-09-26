# `GCRY_SOUND=1` under stress: 2 326 runs, 15 lane-hours, 0 failures

**Dates:** 2026-09-26 16:20 → 19:23 UTC · host: QEMU x86_64, 12 vCPU, Linux 7.0
· tree `52d8e4e` (0.28.0 + the Darwin resident-count change, which is
Darwin-only) · 5 lanes · driver `run-sound.py` (the overnight campaign's
driver with `GCRY_SOUND=1` in every child's environment), raw `results.tsv`.

## Why

The complete root scan's cost is now measured and small
(`../2026-09-26-sound-matrix/`), which puts sound defaults back on the table
(`docs/SOUND-DEFAULTS.md`). What it had never had is tuned's stress record:
every campaign and soak so far ran the tuned profile. This is the first
campaign on the sound one.

Each child booted sound: the same binaries print `"soundness":"sound"` under
`GCRY_SOUND=1` and `"tuned"` without it.

## Result

Process-GC lanes only; the library fuzzer and property test use library
heaps, which the profile does not touch.

| lane | runs | failed | timed out | lane-hours |
|---|---:|---:|---:|---:|
| `churn` | 232 | 0 | 0 | 0.1 |
| `churn_hdr` | 232 | 0 | 0 | 0.1 |
| `index_grow` | 232 | 0 | 0 | 0.4 |
| `pattern_fuzz+diag` | 233 | 0 | 0 | 13.2 |
| `stw_mt` | 233 | 0 | 0 | 0.2 |
| `stw_mt+diag` | 466 | 0 | 1 | 0.6 |
| `stw_mt_hdr_tlab` | 233 | 0 | 0 | 0.2 |
| `stw_mt_hdr_tlab_nursery` | 233 | 0 | 0 | 0.4 |
| `thread_storm` | 232 | 0 | 0 | 0.1 |
| **total** | **2 326** | **0** | **1** | **15.1** |

The one timeout (`stall-stw_mt+diag-20076.txt`) is Crystal 1.21's Parallel
scheduler deadlock, not the profile: both workers running in
`Scheduler#resume` at `parallel/scheduler.cr:97`, the main thread in
`epoll_wait`, no collector frame (`../2026-09-25-parallel-scheduler-deadlock/`).

## Not covered here

Hours: this is 3 h of wall time against the tuned profile's 10 h overnight.
The CI soak (5 h × 3 arms) under `soak_sound=on` is running separately.
