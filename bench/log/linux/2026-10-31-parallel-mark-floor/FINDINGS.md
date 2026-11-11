# Parallel mark below the 32 MiB live floor: no gain on Binarytrees, no default change (2026-10-31)

ROADMAP item "macOS: Binarytrees runs at 88% of Boehm on M1 since 0.37.0",
the part `../../macos/2026-10-23-m1-binarytrees/` put at "~3 points: Boehm's
work on other threads … gcry marks serially below 32 MiB live". The
question: does a lower `GCRY_PARALLEL_MARK_MIN_LIVE` (default
`PARALLEL_MARK_DEFAULT_MIN_LIVE`, 32 MiB, `gc_override.cr`; tested against the
last major's live bytes in `Heap#mark_loop_drain`) or a cheaper parallel
start help Binarytrees on the M1, arm64 or x86, without costing other rows,
pause or CPU?

**Answer: no.** Boehm's own parallel markers do not make Boehm faster on
Binarytrees on any of the three runners (one marker is level or faster), so
there is no "work taken off the main thread" to match; Binarytrees' live set
is under 4 MiB at 219 of its ~231 collections, so a floor anywhere from 4 to
16 MiB leaves it serial; and always-parallel (floor 0) only adds user CPU.
No row of crystal-metric has more than ~12 ms of mark below 32 MiB live.
Nothing is shipped; the default stays.

## Tools (this directory)

- `probe.sh` / `probe.yml`: the probe workflow, push-triggered on
  `probe/mark-floor` (deleted afterwards), checking out the full SHA in `ref:`
  (`5050d270`, this branch's first commit = `release-0.40.0` at `bf607374` plus
  these tools). It builds crystal-metric with Boehm and with gcry and runs
  `bench/runner_ab/ab.py` over environment arms of the two binaries.
- `ms.py`: the local interleaved runner (fresh process per run, shuffled arm
  order, `taskset`), recording the timed section, the process' user + kernel
  CPU (`RUSAGE_CHILDREN` deltas), and from `GCRY_TRACE` Σ mark, Σ pause, the
  largest pause, collections and ns per live object.
- `livescan.sh`: every crystal-metric row once under `GCRY_TRACE`, its
  collections and Σ mark per band of the live bytes the sweep measured
  (`size_class_live_bytes`, the quantity the floor reads at the next cycle;
  large bytes are not in the trace and none of these rows' small-heap
  collections hold large blocks of note).

## Runs

| run | id | what |
|---|---|---|
| probe | [41203148970](https://github.com/sdogruyol/gcry/actions/runs/41203148970) | `macos-latest` (M1, 3 vCPU), `ubuntu-24.04-arm` (4), `ubuntu-latest` (4); Binarytrees, 30 reps per arm in one job, arms below |

Arms: `boehm` (stock, Boehm's default marker count), `boehm1`
(`GC_MARKERS=1`), `gcry` (default: 32 MiB floor), `gcry0`
(`GCRY_PARALLEL_MARK_MIN_LIVE=0`, every mark parallel), `gcry8m`
(`GCRY_PARALLEL_MARK_MIN_LIVE=8388608`), `gcry1` (`GCRY_PARALLEL_MARK=1`,
serial). Each runner's default is two mark workers (master + one helper:
`Heap.default_mark_workers` for 3 or 4 CPUs).

## Boehm's parallel markers do not help Binarytrees

Speed as % of Boehm's default (whole-process wall, median of per-rep paired
ratios, [IQR]) and medians of user CPU s (`probe-41203148970/*.md`):

| runner | `boehm1` speed | `boehm` user | `boehm1` user | `boehm` user + kernel − wall | `boehm1` |
|---|---:|---:|---:|---:|---:|
| `macos-latest` (M1) | 100% [90, 108] | 1.054 | 0.992 | +0.010 | −0.071 |
| `ubuntu-24.04-arm` | **102% [101, 104]** | 1.036 | 0.989 | +0.027 | +0.001 |
| `ubuntu-latest` | **101% [100, 102]** | 0.893 | 0.856 | +0.037 | +0.001 |

Locally (x86-64 QEMU guest, `ms.py`, 11 interleaved runs, timed section /
process CPU, `local-boehm-markers-*.txt`): under `taskset -c 0-3`, Boehm 1
marker 0.605 s / 0.600 s CPU, 2 markers 0.612 / 0.621, 4 markers 0.611 /
0.644; under `taskset -c 0-2`, 1 marker 0.617 / 0.613, 3 markers 0.625 /
0.647.

So Boehm's CPU above its wall time on Binarytrees — the 27 ms that
`../../macos/2026-10-23-m1-binarytrees/` counted as "~3 points: Boehm's work
on other threads" — is its markers' own overhead: with one marker Boehm runs
as fast or faster and spends 37–62 ms less user CPU. That part of the M1 gap
is not there to take; the M1 item's split is corrected in the ROADMAP.

## gcry's floor does not reach Binarytrees

Same run, % of Boehm's default:

| runner | `gcry` | `gcry0` | `gcry8m` | `gcry1` |
|---|---:|---:|---:|---:|
| `macos-latest` | 96% [89, 105] | 97% [91, 102] | 97% [88, 105] | 97% [89, 105] |
| `ubuntu-24.04-arm` | 96% [95, 98] | 97% [96, 99] | 97% [95, 98] | 96% [94, 98] |
| `ubuntu-latest` | 92% [90, 93] | 92% [90, 93] | 91% [90, 93] | 91% [90, 94] |

User CPU s (medians): M1 1.001 / 1.033 / 0.984 / 0.972; arm64 1.037 / 1.072
/ 1.040 / 1.039; x86 0.934 / **1.081** / 0.939 / 0.937. Σ mark ms (medians,
`GCRY_TRACE`): M1 35.1 / 31.1 / 31.8 / 32.9; arm64 33.3 / 32.7 / 34.5 /
36.6; x86 30.8 / 27.6 / 33.4 / 33.4 — 3% of a ~1.07 s run, so even a mark
twice as fast would be worth ~1.5 points.

Every gcry arm is inside every other's range on all three runners. Making
every mark parallel (`gcry0`) moves the wall by nothing and costs 3% (M1,
arm64) to 16% (x86) more user CPU: the helper wakes, polls and parks 230
times for marks of tens of microseconds.

Locally, 9 interleaved runs under `taskset -c 0-3` (`local-floors.txt`;
timed section s, process CPU s, Σ mark ms, largest pause ms): default 0.599 /
0.606 / 20.8 / 2.20; floor 0 0.632 / **0.757** / 18.9 / 1.71; 4 MiB 0.608 /
0.619 / 19.7 / 2.50; 8 MiB 0.602 / 0.611 / 19.6 / 2.24; 16 MiB 0.607 / 0.608
/ 21.7 / 2.25; serial 0.603 / 0.609 / 24.0 / 2.22; Boehm 0.604 / 0.639.
Σ mark spreads 5–30 ms from run to run in every arm: it depends on how many
collections land while one of the large trees is half built.

Why the floor cannot matter: Binarytrees' live set is small. `long_lived_tree`
is dead as soon as it is built (nothing reads it), so the live set is
whichever tree is under construction. `livescan-base.txt`: of 231
collections, 219 end with under 4 MiB live (Σ mark 5.7 ms), 11 with 4–8 MiB
(11.0 ms), 1 with 8–16 MiB (2.0 ms). A floor at 8 MiB makes at most one or
two marks a run parallel; at 4 MiB about a dozen, worth at most ~6 ms if a
second worker halved them, and Binarytrees' ~1 ms marks did not get faster
with a second worker in the `gcry0` arm (Σ mark within the spread above).

## No other row has a mark below the floor worth parallelising

`livescan-base.txt`, Σ mark below 32 MiB live per row (ms): Binarytrees
18.7, Knuckeotide 11.9 (16 collections at 4–8 MiB), JsonParseSerializable
8.6, JsonGenerate 5.1, JsonParsePure 5.7, JsonParsePull 6.0, Primes 1.3,
every other row under 2. The JSON rows' sub-floor marks are their 2–4
ramp-up collections before the heap passes 32 MiB, where the floor already
switches to parallel. The most a lower floor could take from any row is a
few milliseconds of a 0.4–1.3 s run, while `gcry0` shows what an engaged
helper costs in CPU on a small heap; the 32 MiB floor was set to keep a
Kemal heap (a few MiB, 0.3 ms pauses) serial
(`../2026-10-04-parallel-mark-pushbuf/`), and nothing here argues for
lowering it. A "cheaper parallel start" has nothing to save either: the marks
below the floor are microseconds to ~2 ms, and the wake itself is a futex
(`Heap#wake_mark_helpers`).

## Not tried

- Starting serial and engaging the helper mid-cycle once a mark has scanned
  more than N bytes: the only marks it would reach on Binarytrees are the
  ~1 ms ones above, worth ≤1 point even if halved, and Boehm gets nothing
  from its own markers on this row.
