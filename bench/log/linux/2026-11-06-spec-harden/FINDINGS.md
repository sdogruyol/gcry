# Three test-reliability items in the primary CI job (2026-11-06)

Branch `spec-harden-040`, on `release-0.40.0`. Spec-side only: no `src/`
change, so no keep rule and no fixed/control regression of its own. Local
x86-64 Linux, every run under the shared heavy lock, one run per hold.

## 1. Regression 1 runs its cycles in a process of its own

**Before.** On Crystal 1.22.2 headerless, regression 1 still drifted in
suite order after the Monitor fixes, rarely: −1 849, −2 151, −2 444
(`2026-11-04-reg1-drift/` § 5–6). In the one instrumented failure no
recorded root word changed inside the window, so the objects were held by
state an earlier spec left in the shared process — a live heap object, a
pending finalizer or a closure [INFERENCE, holder not named].

**Change** (`process_spec/regression/1_live_objects_dormant_spec.cr`). The
example spawns the spec binary with `-e "live1 child"` and
`GCRY_LIVE1_CHILD=1`, as regressions 95, 99, 100 and 105 do. The child runs
the same `drift_scrub` / `drift_cycle` pair (10 000 then 1 000 blocks,
pre-baseline scrub and four collections, `GC.disable` window, the
`>= baseline + count` check inside the window) and prints
`live1 verdict: <big> <small> <detail>`. The parent requires the child's
success and `1 examples, 0 failures`, echoes the verdict, and asserts the
unchanged bounds: `|big| < 500`, `|small| < 500`, `|big − small| < 500`. The
child runs no other example, so no earlier spec's heap or finalizer state
exists in it.

A first version looked for the verdict at a line start; the child's stdout
progress dot shares the pipe with the stderr verdict and landed in front of
it 3 times in 39 `ba0` runs (`reg1/pre-parsefix/`; the child's drift was 0
each time). The parent now finds the verdict anywhere in the output. The
runs below are all on the final spec.

**Rates** (`reg1/run.sh`; binaries hold this tree's `process_spec` files in
`crystal spec`'s glob order cut after regression 1, 57 files,
`reg1/prefix-entry.cr`; *new* is this branch, *old* is `release-0.40.0`
`4e3ba9be`, interleaved run by run; `reg1/rates-*.txt`):

| config | arm | runs | regression 1 fails | child verdicts |
|---|---|---:|---:|---|
| Crystal 1.22.2 headerless | new | 100 | **0** | 100 of 100 `0 0` |
| Crystal 1.22.2 headerless | old | 74 | 1 (`count=10000 drift=-1881 \| count=1000 drift=0`, run 14) | — |
| 1.21.0 headers + `GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0` | new | 50 | **0** | 50 of 50 `0 0` |

The old arm reproduced the in-suite drift in this window
(`reg1/old-hl122-14-drift.txt`). 0 of 100 against 1 of 74 is not by itself
significant (Fisher two-sided p = 0.43); the case rests on the construction —
the child shares nothing with the specs before it — and on every one of 150
children reading exactly 0 for both counts.

Other failures in these runs, not regression 1 and not this change's:

- Regression 99, *race* control arm (`:628`, child: "the queued slice
  returned false", `Expected 2, got 1` at `:435`): new 1 of 100 and old 3
  of 74 on 1.22.2 headerless, new 2 of 50 on `ba0`
  (`reg1/new-hl122-regression99.txt`). The control's second slice did not
  finish the cycle on the blind marks. The fixed arm never failed. Open,
  not investigated here.
- Regression 21, "controls kept 8 > 1" (`:127`), once: new run 59, 1.22.2
  headerless, with 21's `GC_stackbottom` example pending (3 pending
  instead of 2: the main fiber had moved;
  `reg1/new-hl122-59-regression21.txt`). Both ROADMAP items for this
  message are closed (regressions 103 and 106); this is a recurrence on a
  tree with both. Open, not investigated here. In this order 21 runs
  before regression 1 and after 74, the only changed spec ahead of it
  [INFERENCE: unrelated; old 0 of 74 vs new 1 of 100, Fisher p = 1].

## 2. Regression 74 counts in a chunk its block has to itself

**Before.** 74 allocates 2 900-byte atomic blocks and asserts
`chunk_occupied_count(chunk) == 1` after the stop. On arm64 CI it read 2:
95's failed child's output, an atomic `String` of the same class kept by
the spec runner, sat in the chunk (`2026-11-03-arm64-ci/` § "Regression 74").

**Change** (`process_spec/regression/74_occupancy_claim_pinned_spec.cr`).
`claim74_alone` allocates in the class until a block comes back that is its
chunk's only occupied one (`chunk_occupied_count == 1`), keeping the
earlier blocks live so the cursor does not return to their chunks (bounded
at 4 096 blocks; the example fails if it never gets one). Every assertion
after it is unchanged — claim word, claimed bits occupied before and after
the stop, a set pinned, `live?`, occupied count 1, each claimed block handed
out once, the word `claim | bit`, the count `popcount + 1` — and the fillers
are checked live at the end.

**Proof** (`reg74/run.sh`, `reg74/results.txt`). One binary per arm and
layout from `reg74/entry.cr`: a polluter example that keeps a 2 900-byte
atomic `String` (`reg74/0_pollute74_spec.cr`, on with `POLLUTE74=1`), then
74. *old* is 74 as on `release-0.40.0`; *control* is the new 74 over
`src/` with the fix it pins removed — `bitmap_settle_cursor_sets` no longer
calls `cursor_premark_claim` for a pinned set (`reg74/control.diff`; the
fix is `20cbb8f2`, which added 74). 10 runs each, one process per run.

| layout | polluted | old | new | control |
|---|---|---:|---:|---:|
| headerless | yes | 10 of 10 red | 0 of 10 | 10 of 10 red |
| headerless | no | 0 of 10 | 0 of 10 | 10 of 10 red |
| headers | yes | 10 of 10 red | 0 of 10 | 10 of 10 red |
| headers | no | 0 of 10 | 0 of 10 | 10 of 10 red |

Every old failure is the arm64 one (`chunk_occupied_count … eq(1)`, got
2); every control failure is the defect's
(`(claim74_occ(chunk, word) & claim).should eq(claim)`, got 0: the stop's
sweep cleared the claim). The new 74 is deterministic against the
pollution and still fails on the defect.

## 3. `stw-mt-property-test-release`: scheduler deadlocks, v0.39.0 vs the tip

The loop (`bench/stress_overnight.sh --only='stw-mt-property-test-release'`,
300 runs of `bin/stw_mt_property_test_rel --iterations=400
--workers=2,4,8`, 90 s each) on `v0.39.0` and on the tip (`4e3ba9be`; the
branch changes no `src/` and no harness), alternating v0.39.0, tip,
v0.39.0, tip (`stress/stress_ab.sh`), `HEAVY_LOCK` set to the shared lock
so each run holds it alone. One script for all four: the tip's
`stress_overnight.sh`, and the tip's `run_bounded.sh` and
`stall_capture.sh` copied over v0.39.0's (Linux behaviour the same; the
tip's only adds Windows paths and appends to the log), so the classifier
is identical. `stress/summary-*.txt`:

| tree | round 1 | round 2 | total | gcry fail / stall |
|---|---:|---:|---:|---:|
| v0.39.0 | 4 / 300 | 4 / 300 | 8 / 600 | 0 / 0 |
| tip `4e3ba9be` | 3 / 300 | 3 / 300 | 6 / 600 | 0 / 0 |

Fisher two-sided: this A/B p = 0.79; the earlier same-host A/B (v0.39.0
5 + 4, tip 6 + 9 of 600) p = 0.30; both pooled, v0.39.0 17 / 1 200
against the tip 21 / 1 200, p = 0.62. No difference between the trees.
The 14 / 300 on `2c6a3aa4` was not repeated here [INFERENCE: host load at
the time; the rate is the same tree-independent 1–2 %].

**Logs.** Every `*-sched-*` log from the tip (6, `stress/tip-sched/`) and,
for comparison, from v0.39.0 (8) was read and run through
`stress/sched_verdict.py` (`stress/sched-verdicts.txt`), which flags any
frame under `src/gcry/` other than a service thread's idle wait. All 14 are
the same capture: the `workers=2` stage, both worker threads
(`stw-mt-2-0`, `stw-mt-2-1`) in `sched_yield` ← `Thread.delay` ←
`Parallel::Scheduler#resume` (one under `Channel#receive`, the other under
`Channel#send`, `stw_mt_property_test.cr:207/210`), the main thread in
`epoll_wait` under the scheduler's `run_loop`, the three `gcry-mark`
threads parked in `wait_on_mark_word` (futex), `gc-idle` sleeping in
`loop_forever`, `SYSMON` sleeping in `Monitor#run_loop` through gcry's
`monitor_gate.cr` wrapper. No thread is in a collection, a stop or an
allocation; no log has a gcry frame outside those idle waits. That is
crystal-lang/crystal#17486's resume shape
(`2026-09-25-parallel-scheduler-deadlock/`), and `run_bounded.sh`
classified each one so.

## Checks

On the branch before the docs (`checks.txt`): `rm -rf lib/ameba
bin/ameba`, then `verify.sh` — format (src, spec, process_spec, bench,
samples), `make lint` (259 inspected, 0 failures), `spec/all_specs` 307 /
330 / 307 (invariants), `process_spec` 443 headerless, 444 headers, 444
headers + `GCRY_BITMAP_ALLOC=0`, 0 failures; `make windows-typecheck`,
`make darwin-typecheck`, `make alloc-entry-frame` (5 examples, 0
failures); `process_spec` on Crystal 1.22.2 headerless 443, 0 failures.
No `src/` change, so no keep rule.

## Files

- `reg1/`: `run.sh`, `prefix-entry.cr` (the 57-file order), `rates-*.txt`
  (one line per run), the old arm's failing output, the regression 21 and
  99 outputs, `pre-parsefix/` (the first version's runs).
- `reg74/`: `run.sh`, `entry.cr`, `0_pollute74_spec.cr`, `control.diff`,
  `results.txt`.
- `stress/`: `stress_ab.sh`, `sched_verdict.py`, `sched-verdicts.txt`,
  `summary-*.txt`, `tip-sched/` (the tip's six captures).
