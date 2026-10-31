# The overnight stress on the GitHub runners, weekly (2026-10-31)

`bench/stress_overnight.sh` ran once a release, on one 12-vCPU Linux host. It
now also runs every Saturday on the five runners of `perf-ab.yml`
(`.github/workflows/stress.yml`): `ubuntu-latest`, `ubuntu-24.04-arm`,
`macos-latest`, `macos-15-intel` and `windows-latest`, three jobs each.

## What changed to make it run there

- **Loop selection.** `--only=ERE` / `--skip=ERE` match loop names, so the set
  splits across jobs. Harnesses are built only when a selected loop runs them
  (all nine were built up front before).
- **The heavy lock is optional.** `HEAVY_LOCK=` (set and empty) runs without
  it, and so does a host without `flock` (macOS, Git Bash), which says so once.
- **Exit status.** 1 when any run failed or stalled or a harness did not
  build, after every selected loop; a classified Crystal scheduler deadlock
  (exit 3 of `run_bounded.sh`) is counted and is not a failure. Checked with a
  stub `run_bounded.sh` returning 0/3, 0/3/2 and 0/3/1: exit 0, 1, 1.
- **`date -Is`** is GNU only; the summary's time is `date +%Y-%m-%dT%H:%M:%S%z`.
- **The 1.22 loop** takes its compiler from `STRESS_CRYSTAL_1_22` (default the
  mise install of 1.22.2, the second leg ci.yml moved to) and prints
  `process-spec-crystal-1.22 skipped: no Crystal 1.22 compiler in <dir>` when
  there is none, where it used to vanish from the summary.
- **Windows process specs** are built once into `bin/` from an entry file that
  `require`s every `process_spec/**/*_spec.cr` and run from there:
  `crystal spec` deletes its binary under a handle that outlives the process
  (`ci/windows.ps1`).
- **Loops a runner cannot run say why** (`<name> skipped: <reason>`), from
  probe 41203206908:

  | loop | OS | evidence |
  |---|---|---|
  | chunk-list-drift | Windows | does not build: `LibC.write` (`bench/chunk_list_drift.cr:390`) |
  | realloc-move-stress | Windows | does not build: `LibC::Timespec` (`bench/realloc_move_stress.cr:110`) |
  | soak-smoke | Windows | `bench/soak.cr`: no RSS reader, exit 64 by design |
  | soft-soak-ec4-smoke | any host without `wrk` (Windows) | `ERROR: wrk not found` |
  | chunk-list-drift | macOS, both | its sensitivity checks fail: `window-free arm's trims declined 0 time(s) (want at least 100)`, `refused-releases shipped child made the race 32/33 time(s) in 40 collections`, and on M1 the fast arm hung before its first bucket 3 times |
  | realloc-move-stress | macOS, both | `0 moves (0 MiB)` in every arm: moving 3 of 3 and the control failed |
  | thread-churn-uaf | macOS | M1: `control arm did not reproduce in 32 attempts` (Intel's one run reproduced) |

  None of these is in CI's job for that OS either (`test-windows-gates`,
  `test-macos-gates`), and none is a failure of a shipped arm: each is a
  harness that does not build there or whose control/sensitivity check does not
  fire there, so a run there proves nothing either way. `[INFERENCE]` The macOS
  three are Linux-calibrated (Darwin's large-chunk release and `realloc`
  placement differ); porting them is open, below.

- **Stall capture on Windows** (`run_bounded.sh`, `stall_capture.sh`). Git
  Bash's `ps` has no `-o` and does not see a native process's native children,
  so the tree comes from `Win32_Process`, rooted at `/proc/<pid>/winpid`; the
  capture is cdb's (the image carries the SDK debuggers) attached
  noninvasively, with the executable's directory as the symbol path — the
  executable names its PDB by file name only, and probe 41203206908's capture
  read `stall_selftest+0x115bd2` for every Crystal frame. With it (41208072684):
  `stall_selftest!collect_a_little+0x198 [D:\a\gcry\gcry\src\gcry\collect.cr @ 2163]`,
  `stall_selftest!__crystal_main+0x302a [...\bench\fuzz.cr @ 238]`. The kill is
  `taskkill /T` on the root. cdb prints a line as `parallel\scheduler.cr @ 97`,
  so the scheduler-deadlock classifier matches that form too. `[INFERENCE]`
  The classifier has not yet seen a Windows deadlock capture; it reads the
  same line the Linux gdb form does.
- **The log is appended to.** On Windows the wrapper (`bash -c`) wrote after
  its child was killed, at its own offset, over the `STALLED` line (41203206908:
  the log began `unning after 10 s`). The command's output now opens the log
  with `>>` after a truncate, on every OS.

## The workflow

Three shards a runner, by loop name: `fuzz` (fuzz-60s, property-test,
mt-property-test, both pattern-fuzz), `mt` (the three stw-mt loops, both
claim_stress loops, thread-storm) and `gates` (everything else, as `--skip` of
the other two, so a new loop lands somewhere). Each job installs 1.22.2 and
then 1.21.0 (the primary), gdb + `ptrace_scope=0` and wrk on Linux, wrk on
macOS; runs its shard; then stalls `bench/fuzz.cr` behind a `bash -c` wrapper
for 10 s and requires exit 2, a `STALLED` line, a symbolized frame of the
harness and no harness process left; then uploads `stress-out/` (summary,
every `-fail-`/`-stall-`/`-sched-` log, the self-test's log) and puts the
summary on the job page. Job timeout 355 min.

## Runs

| run | tree | what |
|---|---|---|
| 41203206908 | `0c54b22a` (first cut) | scale 0.05, 15 jobs: 11 green; Windows self-test failed ×3 (no symbols, overwritten log); macOS gates and Windows gates red on the loops in the table above |
| 41208072684 | `c3222171` (skips, Windows capture) | scale 0.05, 15 jobs: 14 green; `ubuntu-24.04-arm, gates` self-test failed only because gdb's `bt 40` stopped short of `__crystal_main` (frames from `src/gcry/os_memory.cr` down to `bitmap_alloc.cr`); the check now accepts any symbolized gcry frame |
| 41208076342 | `c3222171` | **scale 1 on `ubuntu-latest`**, 3 jobs, all green: 1 652 runs, 0 fail, 0 stall, 0 scheduler deadlocks |

Both smoke runs also caught the Crystal scheduler deadlock and classified it
without failing the job (`ubuntu-24.04-arm` and `ubuntu-latest`,
`stw-mt-property-test-release`, 1 run of 15 each in 41208072684, and arm64 in
41203206908;
`smoke-arm64-stw-mt-release-sched-seed773147534.log.gz`: 90 s, 4 threads in
`resume () at .../parallel/scheduler.cr:97`, `STALL CLASSIFIED`). A real failure
fails the job: 41203206908's macOS gates jobs went red on their `-fail-` runs
with the logs in the artifact.

Summaries: `full-ubuntu-latest-{fuzz,mt,gates}-summary.txt` (the full run),
`smoke-41203206908-summaries.txt` and `smoke-41208072684-summaries.txt` (every
job's, prefixed by runner and shard).

## Time

The full set on `ubuntu-latest` (41208076342), job wall time including setup:
fuzz 100 min, gates 88 min, mt 75 min (the 12-vCPU host took about 3.5 h for
all three in a row). Per loop, against the host's 0.39.0 night
(`../2026-10-22-0.39-stress/summary-final-26c25031.txt`):

| loop | runs | ubuntu-latest | host |
|---|---:|---:|---:|
| fuzz-60s | 30 | 1 807 s | 1 807 s |
| property-test | 20 | 144 | 83 |
| mt-property-test | 100 | 302 | 201 |
| pattern-fuzz | 30 | 1 854 | 1 032 |
| pattern-fuzz-headers-freelist | 30 | 1 849 | 1 003 |
| stw-mt-property-test | 200 | 603 | 366 |
| stw-mt-property-test-release | 300 | 604 | 1 022 |
| stw-mt-property-test-headers-freelist | 150 | 303 | 151 |
| claim-stress-lazy | 200 | 1 025 | 1 071 |
| claim-stress-in-stop | 300 | 1 549 | 1 692 |
| thread-storm-release | 200 | 202 | 202 |
| parallel-mark-process | 20 | 82 | 45 |
| parallel-mark-termination | 6 | 32 | 20 |
| mark-audit | 6 | 20 | 14 |
| chunk-list-drift | 6 | 230 | 154 |
| large-cache-race | 10 | 475 | 127 |
| counter-loss | 10 | 171 | 122 |
| claim-stress-gate | 4 | 54 | 50 |
| realloc-move-stress | 6 | 780 | 262 |
| thread-churn-uaf | 4 | 174 | 69 |
| soak-smoke | 6 | 140 | 136 |
| soft-soak-ec4-smoke | 4 | 353 | 299 |
| process-spec | 4 | 681 | 592 |
| process-spec-invariants | 2 | 1 219 | 450 |
| process-spec-headers-freelist | 2 | 502 | 349 |
| process-spec-crystal-1.22 | 2 | 330 | 248 |

The other runners, from 41208072684's per-run seconds × the full counts (one
run per loop at 0.05, so a rough figure; it put `ubuntu-latest`'s fuzz / mt /
gates at 1.67 / 1.72 / 1.16 h against the measured 1.65 / 1.19 / 1.46 h of
loop time, the mt figure inflated by one 90 s deadlock in a 15-run sample):

| runner | fuzz | mt | gates |
|---|---:|---:|---:|
| ubuntu-24.04-arm | 1.41 h | 1.76 h | 1.31 h |
| macos-latest | 1.48 h | 1.59 h | 0.80 h |
| macos-15-intel | 2.45 h | 1.84 h | 1.28 h |
| windows-latest | 1.38 h | 1.30 h | 0.85 h |

The longest, Intel macOS's fuzz shard (pattern-fuzz at 94–122 s a run there
against 47–64 on Linux), is under half the 355-minute job limit.
`[INFERENCE]` The other four runners' full scale is estimated, not run.

## Open

- The three macOS skips and the three Windows build/RSS skips are coverage the
  weekly run does not have: porting `chunk_list_drift`, `realloc_move_stress`
  and `thread_churn_uaf` to Darwin needs their controls re-derived there, and
  the Windows three need a `write`/sleep/RSS shim. Not attempted here.
- The Windows classifier match (`parallel\scheduler.cr @ 97`) waits on a real
  Windows deadlock capture.
- `workflow_dispatch` works once the file is on master; until then the weekly
  schedule does not run either (GitHub reads schedules from the default
  branch).
