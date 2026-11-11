# The in-spin report missed its one spin (2026-11-11)

Branch `watchdog-spin-040`, on `release-0.40.0` (`aac1d0a0`). Local x86-64
Linux, 12 CPUs, Crystal 1.21.0, debug builds as CI builds the gate; every
loop under the shared lock, one per hold.

## 1. The failure

CI run 43004997072, job `test (x86_64, crystal 1.21.0)`, step
`bench/stw_watchdog.cr`:

```
  armed+in-spin    (silent)
FAIL the in-spin report never fired with its threshold at one spin — the line that names the thread a stop is waiting for is unproven
```

The arm runs the child with `GCRY_STW_WATCHDOG_MS=200
GCRY_SUSPEND_STALL_SPINS=1` and expects `gcry: SUSPEND STALLED on thread 0x…`
with `the handle is live`.

## 2. What the report needs, and what 44b75704 changed on its path

The report is `Heap#report_stuck_suspend`, called from the Linux suspend wait
in `stop_world` (`src/gcry/collect_stw.cr`):

```crystal
spins = 0_u64
until suspend_acknowledged?(thread, slot)
  Intrinsics.pause
  spins &+= 1
  if spins == @suspend_stall_spins
    report_stuck_suspend(thread, id, expected, acked, resends)
  end
  ...
```

The count is taken inside the body. A thread whose acknowledgement is already
in when the collector reaches it costs the wait no iteration, so with the
threshold at one the report fires only if some thread is still unanswered when
the collector first checks it. The child's four threads sleep in 2 ms
`Thread.sleep`s; the collector signals all of them and then walks them in list
order. If every one has answered by the time it gets there, nothing fires.

The report reads `StwWatchdog.armed?` (`@@threshold_ns`),
`@suspend_stall_reported` and `@suspend_stall_spins`. 44b75704 touches none of
them: `src/gcry/collect_stw.cr` and `src/gcry/platform/` are identical between
97d866a1 and `aac1d0a0`, and the only changes in `stw_watchdog.cr` are the
initializers of `@@phase` and `@@suspend_step` (constant → literal), which the
watchdog thread's outside report reads and the in-spin report does not. Its
other changes are Monitor and idle-collector state; the `@@exempt` that
decides which threads the wait covers is not among them.

## 3. Rates, both trees, interleaved

`loop.sh` runs the arm's child directly with the arm's env, one build after
another in each round, so every build sees the same load. Four builds of the
arm as CI ran it: `base` (97d866a1), `tip` (`aac1d0a0`), and each with
`probe.diff` applied (`*-instr`), which prints after the wait loop how many
threads it waited for, how many of those cost it at least one spin, and the
total spins. The probe is research only and not committed.

Misses (no `SUSPEND STALLED` line):

| batch | runs/build | base | tip | base-instr | tip-instr |
|---|---|---|---|---|---|
| run1 | 500 | 6 | 2 | 1 | 1 |
| run2 | 3 000 | 9 | 6 | 5 | 6 |
| run3 | 3 000 | 6 | 7 | 4 | 5 |
| run4, every CPU busy (`loaded.sh`) | 400 | 1 | 2 | — | 6 |
| **total** | | **22 / 6 900** | **17 / 6 900** | **10 / 6 500** | **18 / 6 900** |

Both trees miss at 2 to 3 in 1 000; 97d866a1 does not miss less (22 against
17). The local 0/40 on 97d866a1 was a small sample of the same rate.

Instrumented, a miss is exactly a stop whose wait never spun: all 28 misses
read `spun=0`, and none of the 13 372 runs that fired did. The CI failure is
this race.

The probe also shows the wait covering fewer threads than the child started:
`waited` was 1 to 3 in 174 of 13 400 instrumented runs and **0** in two `tip-instr`
runs (one in run3, one loaded) — `GC.collect` ran before any of the four
threads had reached `Thread#start`'s `Thread.threads.push`, so the stop had
nobody to wait for and no setting of the threshold could fire the report.

`run1` and `run2` were taken with the first version of `loop.sh`, which counted
a run as fired on the `SUSPEND STALLED on thread 0x` line alone; `run3` and
`run4` also require `the handle is live`, as the gate does.

## 4. The fix: the arm, not the source

`bench/stw_watchdog.cr` only; no source change, so no CHANGELOG entry, no new
knob and no machine-code diff.

* The in-spin arm adds `GCRY_STW_TEST_DROP_SUSPENDS=1` — the existing research
  knob `make stw-epoch` uses for its `drop+resend` arm — and
  `GCRY_STW_RESEND_SPINS=200000`, that gate's FAST. The first suspend signal of
  the stop is swallowed. The drop and the wait walk the same list with the same
  filters, so the dropped thread is the first one waited for, and nothing can
  answer for it until the wait has spun 200 000 times and resends. The report
  fires at spin one of that wait; the resend is what lets the stop finish.
* The child waits until all four threads have started before it collects, so
  the stop has threads to wait for (and the suspend arm's `n of m` cannot be
  `0 of 0`).
* The child prints its heap's `stw_suspend_dropped_for_test` and
  `stw_suspend_resends` on stderr, and the gate fails the in-spin arm unless
  both are non-zero: the spin that makes the arm deterministic is checked, not
  assumed. Without the drop the counts are `dropped=0 resends=0`
  (`barrier-only`, run3, 3 000 of 3 000), which this check rejects.

The existing assertions are unchanged: the arm must print `SUSPEND STALLED on
thread 0x` and `the handle is live`. What it proves is the same report, fired
for a thread that has not answered, instead of for whichever thread the
scheduler happened to make slow.

## 5. Results on the fix

| batch | runs/build | barrier-only | fix | fix-instr |
|---|---|---|---|---|
| run3 | 3 000 | 8 missed | **0** | **0** |
| run4, every CPU busy | 400 | — | **0** | **0** |

`barrier-only` is the fixed child with the CI arm's env: the start barrier
alone does not close the race (8 / 3 000, same as base and tip). `fix` and
`fix-instr` are the fixed child with the fixed arm's env: 3 400 runs each, 0
missed, every one `dropped=1 resends=1`. `fix-instr` waited for 4 or 5
threads in every run (never fewer: the barrier), spun on exactly one, for
200 000 to 295 167 spins.

The whole gate, fixed, 200 runs (`gate_loop.sh`, four loops of 50 in
parallel): 200 PASS, every in-spin row
`SUSPEND STALLED on thread 0x… — 0 of 4 acknowledged, … the handle is live`
(`runs/gate-fix-200.txt`).

The looped builds were made from this bench before its comments were last
edited; its code is the committed code.

## 6. Checks

`checks.sh`, output in `checks.txt`: format, `make lint` (after `rm -rf
lib/ameba bin/ameba`), `make knob-doc-check`, `make stw-watchdog`,
`make windows-typecheck`, `make darwin-typecheck`, the gate cross-compiled for
both Windows and both Darwin targets (it runs on those jobs), `make
alloc-entry-frame`, `make spec-process`.

## Files

* `loop.sh`, `loaded.sh`, `tally.sh` — the interleaved child loop, the same
  with one spinning shell per CPU, the per-build tally.
* `gate_loop.sh` — the whole gate N times.
* `probe.diff` — the wait-loop probe of the instrumented builds.
* `runs/run*-tally.txt`, `runs/run*-misses.txt` — per batch; the raw run files
  (one line per run, up to 21 000 a batch) are not kept.
* `runs/gate-fix-200.txt` — the fixed gate's 200 runs.
* `checks.sh`, `checks.txt`.
