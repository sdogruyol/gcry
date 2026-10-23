# macOS `tlab-nursery-sample` "hung twice" (2026-09-29): one hang, Crystal's scheduler deadlock (2026-10-21)

ROADMAP item "macOS: `tlab-nursery-sample` hung twice (2026-09-29)". The
question for 0.39.0: was the hang the freed-main-fiber defect fixed in 0.38.0
(`a00f5c47`, `bench/log/macos/2026-10-19-tlab-nursery-crash/`), and is it gone
on master?

**Verdict: neither the freed-fiber defect nor any other gcry defect.** The
record has one hang in this step, not two. Its log matches, line for line, the
twelve stalls of this harness that `sample` has captured on macOS (two on CI,
ten in the probe below). Every one of those twelve is Crystal 1.21's
Parallel-scheduler deadlock, crystal-lang/crystal#17486: two worker threads
spin in `Scheduler#resume` at `scheduler.cr:97`, each waiting on the other's
fiber; the main thread sits in `kevent`; no collector frame is on any stack
and no watchdog line is printed.

The probe ran the step's harness 10 000 times, bounded and captured, on
macos-latest and macos-15-intel. It used three builds: master (`9157672e`),
the build that hung (`d1549e2f`) and v0.37.0 (`16b7e67c`, before
`a00f5c47`). No build stalled in gcry: **0 exit-2 stalls in 10 000 runs**,
0 in master's 4 000. The upstream deadlock came at the same rate on all
three (master 4 / 4 000, `d1549e2f` 4 / 4 000, v0.37.0 2 / 2 000), and the
bounded runner classifies it and does not count it.

The freed-main-fiber defect cannot be reached from this harness: it needs a
`scan_stack: false` collection, and neither the harness nor `src/` asks for
one. `bench/run_bounded.sh` already turns #17486 into exit 3 on macOS, so the
step stays honest without any change. Nothing here needed a fix, so there is
no regression test.

## What the item recorded, against the CI record

The item reads: "cancelled at its 20-minute limit on `8bc11c8` and on
`d1549e2` … both in that step … the one log that survived is `tlab-only` seed
10: it printed nothing after collection 2, and the watchdog printed nothing
either. Rate: about 2 in 280 runs." Read against the job logs:

- **`8bc11c8a` (run 36579415248, job 109443327263) did not hang in this
  step.** The sampler step was *skipped*. The job was cancelled in "Unit +
  process specs + samples on Darwin", in `make fiber-list-exit-race`, whose
  red-arm children timed out three times at 5 minutes each
  (`ci-history/job109443327263-excerpt.log`). `dba51e27`, the same
  afternoon, capped that wait ("its children hang rather than lose
  objects").
- **`d1549e2f` (run 36595035838, job 109497630249) is the one sampler
  hang.** The step started 16:14:03 and was cancelled 16:24:58, when the job
  hit its 20 minutes (`ci-history/job109497630249-sampler-step.log`). The
  artifact holds `tlab-only-10.log`, the step's 40th and last run
  (`ci-history/run36595035838-d1549e2f-tlab-only-10.log`).
- **"Nothing after collection 2" is a report limit, not the place of the
  hang.** The three lines it ends with are the dying-type audit's
  `a thread was staged AFTER the wait ran` precondition (`GCRY_THREAD_BLOCK_AUDIT=1`).
  `THREAD_POP_REPORT_LIMIT = 3` (`src/gcry/thread_block_audit.cr`), so that
  line is printed for collections 0, 1 and 2 of every process and never
  again. The harness prints nothing per collection. The log says only that
  the run was in its `workers=2` phase, because the `workers=4` header never
  came, somewhere between collection 3 and that phase's final collect. Every
  passing run's log reads the same up to that point.
- **"The watchdog printed nothing" means no stop was stuck.**
  `GCRY_STW_WATCHDOG_MS=10000` was set. At `d1549e2f`, Darwin's `stop_world`
  enters `PHASE_SUSPEND` before it takes the fiber list's mutex or makes any
  libpthread call (`src/gcry/collect_stw.cr`), and `start_world` calls
  `StwWatchdog.leave` only after `Platform.start_world_threads` has resumed
  every thread. Every phase in between is entered with `StwWatchdog.enter`.
  The watcher is a raw pthread outside Crystal's thread list, so the stop
  never suspends it. It polls every 50 ms and reports a phase older than the
  threshold with `write(2)` (`src/gcry/stw_watchdog.cr`). It stayed silent
  for about nine minutes, so the process was not inside a stop.
  [INFERENCE: that the watcher was alive in that process. Its code did not
  change between `d1549e2f` and `a54adeed` (2026-10-01), which put it under
  the Darwin `stw_watchdog` gate, and the gate passed.]

Exposure of the step on Darwin (`test (darwin native)`, macos-latest only;
`ci-history/`). The jobs API calls a `continue-on-error` step green even when
it failed, so `step_outcomes.py` reads each job log's
`tlab-nursery-sample:` summary line, and `tally.py` sorts the jobs by which
fixes their tree contains:

| CI era (by the job's tree) | steps | runs | gcry stalls | #17486 (exit 3) | other |
|---|---:|---:|---:|---:|---|
| before the pthread list-lock fix (2026-09-22 .. 09-30) | 213 + 1 cancelled | 7 910 | 1 unbounded hang (`d1549e2f`), uncaptured | — (unbounded until `295780d9`) | 1 crash, see below |
| pthread fix (`9c19480`/`131f626`) .. v0.37.0 | 266 + 2 cancelled | 10 640 | 0 | 2 | — |
| `a00f5c47` .. master | 10 | 400 | 0 | 0 | — |

The two cancelled steps of the middle era (`91cf7925`, `50b1315e`) were cut
off 57 s and 144 s in, by the runs being cancelled, not by the 20-minute
limit (their jobs had run 11.5 minutes). A step takes 132 s at p50 and 308 s
at most, so neither shows a hang. The item's "2 in 280" counted the
`8bc11c8` cancellation too. Ten steps (400 runs) ran between `faf4c4df`,
which first held the fiber list across the stop, and the `d1549e2f` hang.

## The same log, captured: two CI stalls on macOS

After `295780d9` bounded each run, the Darwin step classified two stalls as
upstream. Their artifacts hold the `sample` captures:

- run 36786111983, `44d79958` (2026-09-30), `tlab-only-3.log`
- run 37437660646, `a4c0dbde` (2026-10-06), `tlab-only-7.log`

(`ci-history/run*-tlab-only-*.log`.) Before the capture, each reads line
for line as the `d1549e2f` log does, apart from the page-size warning
`d1549e2f` still printed: the tlab-only header, `STW-MT workers=2
iterations=200`, the three audit lines for collections 0–2, and nothing
else. In each capture, `stw-mt-2-0` and `stw-mt-2-1` spin in
`Fiber::ExecutionContext::Parallel::Scheduler#resume` at `scheduler.cr:97`
(1 408 and 1 403 of 1 436 samples in the first), one reached from
`Channel#send` and the other from `Channel#receive`. The main thread is in
`kevent`, SYSMON is in its run loop, and `gc-idle` is in `nanosleep`. The
STW watchdog's own thread is in the capture too, alive in `watch_loop`'s
`nanosleep` (`stw_watchdog.cr:227`): it is silent because no phase is open,
not because it is dead. That is the circular wait of
`bench/log/linux/2026-09-25-parallel-scheduler-deadlock/`, which reproduces
under Boehm and with no GC calls at all.

## The probe

Run [39653275203](https://github.com/sdogruyol/gcry/actions/runs/39653275203),
probe commit `dbb17b7c` on branch `probe/mac-tlab-hang`, deleted after the
run. The workflow is `probe-ci.yml` and the loop is `probe_loop.sh`. Each job
checks out one build into its own worktree and builds
`bench/stw_mt_property_test.cr` with `-Dgc_none -Dgcry_block_headers`, as
the make target does. It then runs 25 "steps" serially. Each step is the CI
step's 40 runs: 30 `--nursery --iterations=50` with seeds 1..30, then 10
`--iterations=200` with seeds 1..10, all `--tlab --workers=2,4`, under the
target's environment
(`GCRY_BITMAP_ALLOC=0 GCRY_POISON_HOLDERS=1 GCRY_THREAD_CENSUS=1
GCRY_THREAD_BLOCK_AUDIT=1 GCRY_STW_WATCHDOG_MS=10000`). Each run is bounded
at 120 s by master's `bench/run_bounded.sh`, which on a stall captures
`sample` output and classifies it. The jobs ran 0.8–1.7 h each.

| runner | build | runs | gcry stall (exit 2) | #17486 (exit 3) | failed | slowest passing run |
|---|---|---:|---:|---:|---:|---:|
| macos-latest | master `9157672e` | 2 000 | **0** | 2 | 0 | 21.3 s |
| macos-latest | `d1549e2f` (hung on CI) | 2 000 | **0** | 2 | 1 | 17.7 s |
| macos-latest | v0.37.0 `16b7e67c` | 1 000 | **0** | 1 | 0 | 9.6 s |
| macos-15-intel | master `9157672e` | 2 000 | **0** | 2 | 0 | 19.4 s |
| macos-15-intel | `d1549e2f` | 2 000 | **0** | 2 | 0 | 19.7 s |
| macos-15-intel | v0.37.0 `16b7e67c` | 1 000 | **0** | 1 | 0 | 18.3 s |
| **all** | | **10 000** | **0** | **10** | 1 | |

Jobs (shard 1 / shard 2): macos-latest master 119406870820 / 119406870860,
`d1549e2f` 119406870453 / 119406870637, v0.37.0 119406870030; macos-15-intel
master 119406870717 / 119406870523, `d1549e2f` 119406870696 / 119406870718,
v0.37.0 119406870616. Summaries and every kept log are in `probe/`.
`classified.txt` is `classify_stalls.py` over them, and `nonzero-rc.csv`
lists every run that did not exit 0.

All ten exit-3 stalls have the same shape (`classified.txt`): exactly two
worker threads at `scheduler.cr:97` (`stw-mt-2-*` in seven, two of the four
`stw-mt-4-*` in three), the main thread in `kevent`, no
`stop_world`/`run_collection`/`Gcry::Heap#collect`/`pthread_mach_thread_np`
frame, and no watchdog line. Seven were in the tlab-only arm, three in the
nursery arm. The slowest passing run took 21.3 s against the 120 s bound, so
a slow run cannot be mistaken for a stall.

Rates. gcry stalls: 0 / 4 000 on master gives a 95% upper bound of about
0.075% per run (rule of three), and 0 / 10 000 across all builds gives 0.03%.
#17486: 10 / 10 000, about 0.1% per run, or about 4% per 40-run CI step. The
three builds are indistinguishable (4 / 4 000, 4 / 4 000, 2 / 2 000). Before
the bound, the deadlock would have eaten the job, as it did on `d1549e2f`.
The CI step met it 3 times in 18 950 runs, counting the `d1549e2f` hang,
against the probe's 10 in 10 000. The two CI captures and the probe's
macos-latest captures all report macOS 26.6.2. [INFERENCE] The probe's
back-to-back runs on an otherwise idle runner differ from a step that runs
after twenty others. Not investigated, since the deadlock is upstream.

## Was it the freed-main-fiber defect (`a00f5c47`)?

No, by the code. That defect needs a collection that skips every other
thread's stack, which before `a00f5c47` meant one asked for with
`scan_stack: false` (`run_collection_body` gated `scan_all_fiber_roots`,
`scan_thread_roots`, `scan_other_thread_stacks` and
`scrub_parked_fiber_stacks` on it). The harness's collections are
`GC.collect` (`gc_override.cr`: `heap.collect(release_warm: true)`) and
`Gcry.default_heap.minor_collect` with no argument. Both default to
`scan_stack: true` at `d1549e2f`, at v0.37.0 and on master. The automatic
paths pass `scan_stack: true` or nothing (`heap.cr`, `tlab.cr`,
`collect.cr`'s coalescing calls). No `scan_stack: false` and no
`collect(false` appears in `src/` at `8bc11c8a`, at `d1549e2f` or on master
(`git grep`). So `other_stacks_are_roots?` is true in every collection this
harness makes, before and after the fix, and the newborn thread's frame was
always scanned.

In principle a freed, listed fiber could hang a process as well as crash it.
A walk could follow a reused block's `next` around a cycle, or a scheduler
could spin in `resume` on a reused block whose `resumable?` byte never
turns true. Neither can happen without the free, and this harness never
causes it. The probe agrees: v0.37.0 (before `a00f5c47`) and master show
the same 0 gcry stalls and the same #17486 rate.

## Was it the pthread list lock (the item's "probable cause")?

[INFERENCE] No. `d1549e2f` does predate that fix: `9c19480` resolved every
port and bound before the first suspend, and `131f626` held the thread-list
mutex across the stop (`bench/log/macos/2026-09-29-pthread-list-lock/`). That
defect deadlocks inside the stop, either in `pthread_mach_thread_np` during
the suspend or resume, or in the stack-bounds lookups during the scan. Those
places are in `PHASE_SUSPEND`, `PHASE_STACKS` or `PHASE_RESUME`, where the
watchdog reports, and the `d1549e2f` log has no report. In 4 000 probe runs
of `d1549e2f` itself it did not happen once. This harness starts its
threads only as each `run_one` brings up its Parallel context, plus
`gc-idle` once, so the window that `thread_birth_fiber` opens 300 times a
run is rarely open here. That fix is real and stays. It was the cause of the
`thread-birth-fiber` hangs, not of this one.

## Side observations, not this item

- **Probe, `d1549e2f`, macos-latest: one live-object loss.** Tlab-only,
  seed 6, `workers=4`: `after collect #151: root 11 DEAD … block={found:
  true, free: true, size: 64 …}` (`probe/macos-latest-pre-1/tlab-only-s1-6.log`).
  There were none in the 6 000 runs of v0.37.0 and master. `d1549e2f`
  predates at least two Darwin stop fixes: the pthread list lock above, and
  the late clear of
  `@world_stopped` after the resume, which let resumed threads read the chunk
  index unlocked (`bench/log/macos/2026-10-01-darwin-index-late-clear/`,
  fixed 2026-10-01). [INFERENCE] One of those. Not pursued.
- **CI, `b9394a01` (run 36360833882, 2026-09-28): one crash.** A new thread's
  `Fiber.new` died in `tlab_alloc_small` → `oom!("failed to refill TLAB size
  class", 192)`, and the backtrace dump then failed with `Thread#current_fiber
  cannot be nil` (`ci-history/run36360833882-b9394a01-tlab-nursery-8.log`).
  It is the only failure in 18 950 CI runs of this step, none like it came
  in the probe's 10 000 runs, and headered TLAB is unsupported. It was not
  recorded before this note.

## Files

- `probe-ci.yml`, `probe_loop.sh`: the probe workflow and the loop it runs.
- `probe/<runner>-<build>-<shard>/`: each job's summary and kept logs
  (`pre` = `d1549e2f`). The `sample` captures have their Binary Images list
  trimmed. The full outputs are in run 39653275203's artifacts.
- `probe/classified.txt`, `probe/nonzero-rc.csv`, `classify_stalls.py`.
- `ci-history/`: `exposure.py` (every ci.yml run's `test (darwin native)` job
  since 2026-09-22), `step_outcomes.py` (each step's summary line from its
  job log), `tally.py` and its output `tally.txt`, the `d1549e2f` hang log,
  the two captured CI stalls, the `b9394a01` crash, and the two job excerpts
  above.
