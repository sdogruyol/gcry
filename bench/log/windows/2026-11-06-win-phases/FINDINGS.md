# Windows JsonParsePure and Binarytrees on the 0.40 tip, four phases a side (2026-11-06)

The second numbers run (Perf A/B 41577045896 on `2658369a` against
`v0.39.0`, two pads a side, `../2026-11-05-0.40-runners/`, keep rule in
`../../linux/2026-11-05-0.40-runners/keep.txt`) left two Windows rows
unexcused, both on an EPYC 7763: JsonParsePure, timed +7.5% [+6.1, +8.6]
(wall +3.0%), and Binarytrees, wall +0.7% [+0.0, +3.8]. This file runs
WinRows' protocol (`../2026-11-02-0.40-win-rows/` §1: every 16-byte phase of
both trees in one session) on the current source, adds the source at
`2c600dfb` and at `e7efe740` as checkpoints, and then the tip less each
group of the commits after `e7efe740`.

**Verdict: both rows are code placement; nothing to fix.**

- **JsonParsePure.** In six sessions on three CPUs the 0.40 range
  overlaps 0.39.0's in the timed section. At the same phase, wall time is
  0.6–2.1% *faster* on 0.40 in every session. 0.40 has one collection less,
  in the setup before crystal-metric's `GC.collect` that comes ahead of the
  timer (§2). On the EPYC 7763 the timed section reads +1.5% to +2.0% pooled
  over the four phases (four sessions). The slow phase is 48, the one where
  0.39.0 runs fastest; at phase 16, 0.40 is level or faster in all four. On
  the EPYC 9V45 it reads −2.1% and on the Xeon 8573C −0.2%. The checkpoints
  read level with 0.39.0: `2c600dfb` +0.4%, −0.4%, +1.1% and `e7efe740`
  −0.4%, +0.6%, +0.1% pooled. No group of the 15 later `src` commits,
  reverted, lowers the band at every phase on the 7763 (§3). The two groups
  that bring it to 0.39.0's level do so through one or two phases, and one of
  them removes code that runs once per process on Windows. Its removal also
  moves the control that allocates nothing by +2.8% on the 9V45. The numbers
  run's +7.5% is 0.40 unpadded at phase 32 (slow) against 0.39.0 unpadded
  at phase 48 (fast on this CPU): +3.1% to +5.4% in these sessions.
- **Binarytrees.** In three sessions on the EPYC 7763 the two trees' ranges
  meet: their minima are equal to 0.001 s in two sessions and 0.40's is 0.003
  s higher in the third. At the same phase, 0.40 reads +0.4%, +0.8% and +0.5%
  pooled in timed section and +0.2%, +0.8% and +0.4% in wall time. The
  slow cell is phase 32, where unpadded 0.40 sits (+1.4% to +2.3%).
  `2c600dfb`, whose word advance is also inline, reads −0.6%, 0.0% and −0.5%.
  This is `../2026-11-03-binarytrees/` §5 on this CPU: with the advance
  inline (`da2082e1`), 0.40 averages 0.39.0's time over the placements.

The keep rule's unexcused rows are therefore placement, as the four-pad
keep run had found (41297103900) and two pads could not show: 0.40's fast
phase on the 7763 (16) is reached by its 32-byte prepad, which the numbers
run does not build. No `src` change, so no regression and no keep-rule run.

## Method

`perf-ab`'s `bench/runner_ab/ab.sh`, run by a push-triggered probe workflow on
`windows-latest` (`probe/probe-win-phases.yml`; branch `probe/win-phases`,
deleted, its two tips tagged `archive/probe/win-phases-1` and `-2`), with
WinBT's probe additions (`probe/ab-probe.patch`: `AB_REVS` builds another
revision's `src/`, and `AB_PATCHES` the tip with a patch, each prepadded
when given `:pN`). Crystal 1.21.0, 21 interleaved reps, no Boehm arm.
`base` = `v0.39.0` (`c0d570c5`), `var` = the tip (the probe's `src/` is
`2658369a`'s; `origin/release-0.40.0` has changed only docs and bench logs
since). Pads `p16 p32 p48 p64 bp16 bp32 bp48 bp64`: each tree unpadded and
prepadded by 16, 32, 48 and 64 bytes. A phase is `Revcomp#revcomp`'s address
mod 64 in the arm's link map, as in WinRows (`phases.py`). The control is
Fannkuchredux (3 collections a run). Each session's CPU is the runner's
`Win32_Processor` name (`cpu.txt`).

| round | run | probe tip | arms | sessions (CPU) |
|---|---|---|---|---|
| 1 | 42256500844 | `833a244a` | pads; `c2c` = `src/` at `2c600dfb` and `ce7` = at `e7efe740`, each unpadded, p16, p32, p48; JsonParsePure, JsonParseSerializable, JsonParsePull, Binarytrees, Fannkuchredux | s1, s2, s3 (EPYC 7763) |
| 2 | 42271548920 | `5399d3b5` | pads; `pt_<group>`: the tip less a group of commits (src only, `probe/rv-*.patch`), each unpadded, p16, p32, p48; JsonParsePure, Fannkuchredux | s1 (EPYC 7763), s2 (EPYC 9V45), s3 (Xeon Platinum 8573C) |

Round 2's groups cover every `src` commit after `e7efe740` (`git log
e7efe740..2658369a -- src`). Each patch is the commits' `src/` diffs
reverse-applied newest first. Each reverted tree cross-compiles for
`x86_64-windows-msvc` (`samples/hello.cr`, `--release`).

| arm | reverts | what it is on Windows |
|---|---|---|
| `pt_hot` | `da2082e1`, `19cf3a60` | the hot heap fields declared first (the advance is inline on Windows either way) |
| `pt_heap` | `2721f940`, `9f0c139d` | `GC_base`/`GC_size`/finalizer claim checks; a regression-86 hook in the slow path |
| `pt_scrub` | `2c6a3aa4`, `23a78cd9`, `e2737a33` | the pre-scan scrub's bounds, the idle loop's and the scan's frame wipes, the band wipe (inside a collection or before an idle park) |
| `pt_monitor` | `2658369a`, `7bfb0358`, `c38b75b6`, `cbd318f2` | the monitor gate's stack scrubs. The per-call scrub is `{% if flag?(:linux) %}`; on Windows only the loop-entry scrub runs, once per process |
| `pt_incr` | `617a1657`, `c51890f8`, `258f88e5`, `21462240` | the incremental drain and finish, the pthread scan clamp |

`sessions/` holds each session's runs, trimmed to time, wall, user, system,
faults, peak, collections, Σ mark and Σ pause, with its phases and CPU
(`<run>-<session>.json`), and its `summary.md`. `phases.py` prints the
tables below from those files or from an artifact directory
(`round{1,2}-{time,wall}.txt`; `round1-trees.txt` holds the per-tree
counters). Medians in seconds. "Pooled" is each 0.40-code arm against the
0.39.0 arms at its phase, paired per rep, median [interquartile range].

## 1. Round 1: four phases of each tree, two checkpoints (EPYC 7763 ×3)

JsonParsePure, timed section (`sessions/round1-time.txt`):

| session | tree | phase 0 | 16 | 32 | 48 | range | mean over phases | pooled vs 0.39.0 |
|---|---|---|---|---|---|---|---|---|
| s1 | 0.39.0 | 0.830 | 0.823 | 0.836 | 0.811, 0.811 | 0.811–0.836 | 0.825 | |
| | 0.40 | 0.841 | 0.822 | 0.846, 0.843 | 0.833 | 0.822–0.846 | 0.835 | +1.5% [−0.2, +3.1] |
| | `2c600dfb` | 0.835 | 0.830 | 0.837, 0.837 | — | 0.830–0.837 | | +0.4% [−1.2, +1.5] |
| | `e7efe740` | — | 0.808 | 0.801 | 0.813, 0.824 | 0.801–0.824 | | −0.4% [−2.0, +1.5] |
| s2 | 0.39.0 | 0.883 | 0.878 | 0.884 | 0.859, 0.857 | 0.857–0.884 | 0.876 | |
| | 0.40 | 0.892 | 0.861 | 0.885, 0.890 | 0.891 | 0.861–0.892 | 0.883 | +1.5% [−0.7, +3.7] |
| | `2c600dfb` | 0.875 | 0.864 | 0.885, 0.883 | — | 0.864–0.885 | | −0.4% [−2.0, +1.2] |
| | `e7efe740` | — | 0.871 | 0.852 | 0.877, 0.870 | 0.852–0.877 | | +0.6% [−1.1, +2.2] |
| s3 | 0.39.0 | 0.832 | 0.823 | 0.830 | 0.815, 0.809 | 0.809–0.832 | 0.824 | |
| | 0.40 | 0.849 | 0.813 | 0.856, 0.851 | 0.833 | 0.813–0.856 | 0.837 | +2.0% [+0.2, +3.3] |
| | `2c600dfb` | 0.841 | 0.821 | 0.839, 0.844 | — | 0.821–0.844 | | +1.1% [−0.2, +2.2] |
| | `e7efe740` | — | 0.818 | 0.804 | 0.812, 0.829 | 0.804–0.829 | | +0.1% [−1.7, +2.2] |

(Two medians in a cell: the unpadded arm and the one padded by 48 or 64
that lands on the same phase. The checkpoints' pads reach three phases;
their means are not comparable, so their column is blank.)

- **The ranges overlap in every session.** 0.40 against 0.39.0 at each
  phase: 0: +0.8%, +0.3%, +1.4%; 16: +0.4%, −1.6%, −1.1%; 32: +0.9%,
  +1.4%, +2.6%; 48: +3.0%, +3.9%, +2.3%. 0.39.0's fast phase on this CPU is
  48, and 0.40's is 16.
- **Wall time at the same phase: 0.40 is faster**, pooled −0.7% [−2.3,
  +1.0], −0.9% [−2.5, +0.9], −0.6% [−2.2, +0.6] (`round1-wall.txt`).
- **The checkpoints read with 0.39.0.** `2c600dfb` is WinRows' measured
  source on Windows (`src/` at `07b61d28` is the same), and `e7efe740` has
  the growth-priced pace (13 collections, the tip's Σ mark).
  `e7efe740` reaches the fastest cells of the session (0.801 s at phase
  32 in s1).
- **JsonParseSerializable and JsonParsePull** read level: pooled +0.6%,
  +0.6%, +0.4% and +0.0%, +0.2%, +0.5% timed, −0.6% to −1.2% wall.
  `e7efe740` reads +2.4% to +3.3% pooled on both rows, with −2.2% to −3.5% at
  phase 32 and +2.5% to +4.5% at 16 and 48. That is a same-phase offset as
  large as JsonParsePure's from a tree that the tip contains, with more code
  on top.
- **Fannkuchredux** (the control): pooled +0.1%, +0.1%, −0.1%.

## 2. The collection 0.40 does not run is in the setup

0.40 and `e7efe740` collect JsonParsePure 13 times, and 0.39.0 and
`2c600dfb` 14 times. Σ mark is 231 ms against 256 ms, and Σ pause 241 ms
against 266 ms (`round1-trees.txt`, s1). The extra collection is a second
scan at 119.9 MiB live in the setup (JsonGenerate 600 000 and its `to_s`).
From crystal-metric's `GC.collect` before the timer (`metric.cr`, `_run`;
the 42.9 MiB scan) on, every tree runs the same collections over the same
live sizes (`setup-collections.txt`). So the pace's change is all
outside the timed section: it shortens the wall time and leaves the
timed section's collector work alone. Peak working set is level
(553–555 MiB in every tree).

## 3. Round 2: the commits after `e7efe740`, reverted in five groups

JsonParsePure, timed section, mean over phases and pooled against 0.39.0 at
the same phase (`sessions/round2-time.txt`):

| session (CPU) | 0.39.0 | 0.40 | `pt_hot` | `pt_heap` | `pt_scrub` | `pt_monitor` | `pt_incr` |
|---|---|---|---|---|---|---|---|
| s1 (EPYC 7763) | 0.803–0.833 | 0.811–0.846, +1.5% [−0.1, +3.0] | 0.836–0.850, +1.8% | 0.819–0.847, +1.4% | 0.809–0.849, +0.0% | 0.793–0.845, −0.2% | 0.822–0.848, +1.7% |
| s2 (EPYC 9V45) | 0.535–0.552 | 0.528–0.539, −2.1% [−4.0, +0.4] | 0.530–0.540, −1.5% | 0.531–0.534, −1.1% | 0.535–0.559, +0.8% | 0.525–0.537, −1.1% | 0.525–0.539, −0.6% |
| s3 (Xeon 8573C) | 0.825–0.862 | 0.830–0.855, −0.2% [−2.7, +1.7] | 0.834–0.862, +0.1% | 0.815–0.857, −1.3% | 0.815–0.860, −0.4% | 0.814–0.846, −1.6% | 0.825–0.848, −1.0% |

- **The 7763's residual is the 7763's.** 0.40 reads +1.5% pooled here, as in
  round 1, and −2.1% on the 9V45 and −0.2% on the 8573C. Wall time at the
  same phase is faster on all three: −0.9%, −2.1%, −0.8%
  (`round2-wall.txt`).
- **No group carries it.** `pt_hot`, `pt_heap` and `pt_incr` read like
  the tip (+1.4% to +1.8%). `pt_scrub` and `pt_monitor` reach 0.39.0's level
  (+0.0%, −0.2%) through their phase-16 and phase-48 cells: `pt_monitor`'s
  phase 16 is 0.793–0.796 s, under every 0.39.0 arm. At phase 0 both stay
  +1.2–1.3% above 0.39.0, like the tip (+1.7%). On Windows `pt_monitor`
  removes code that runs once per process, and on the 9V45 the same arm
  moves the control +2.8% [+1.3, +4.2] (Fannkuchredux allocates nothing).
  `pt_scrub` removes three stack wipes that run inside a collection or
  before the idle thread parks; the pre-scan scrub costs 1.5–2 µs a
  collection (`../2026-11-03-binarytrees/` §2), and this row
  collects 13 times. [INFERENCE] Both arms move the row by shifting
  gcry's code relative to the rest of the program, which a prepad cannot
  vary (it moves all code together). The same kind of offset separates
  `e7efe740` from the tip on the other JSON rows (§1).
- **Control:** Fannkuchredux pooled −0.1% (7763), +0.2% (9V45), −0.5%
  (8573C) for the tip; every revert arm is within ±1.2%, except
  `pt_monitor` on the 9V45.

## 4. Binarytrees (round 1, EPYC 7763 ×3)

| session | tree | phase 0 | 16 | 32 | 48 | range | pooled vs 0.39.0: time | wall |
|---|---|---|---|---|---|---|---|---|
| s1 | 0.39.0 | 1.295 | 1.281 | 1.266 | 1.273, 1.279 | 1.266–1.295 | | |
| | 0.40 | 1.296 | 1.266 | 1.295, 1.281 | 1.276 | 1.266–1.296 | +0.4% [−1.3, +1.7] | +0.2% [−1.6, +1.9] |
| | `2c600dfb` | 1.281 | 1.258 | 1.271, 1.282 | — | 1.258–1.282 | −0.6% [−1.9, +0.8] | |
| s2 | 0.39.0 | 1.361 | 1.329 | 1.327 | 1.331, 1.333 | 1.327–1.361 | | |
| | 0.40 | 1.353 | 1.330 | 1.370, 1.368 | 1.334 | 1.330–1.370 | +0.8% [−1.1, +2.8] | +0.8% [−1.8, +3.9] |
| | `2c600dfb` | 1.355 | 1.325 | 1.321, 1.329 | — | 1.321–1.355 | −0.0% [−1.5, +1.5] | |
| s3 | 0.39.0 | 1.305 | 1.293 | 1.291 | 1.301, 1.298 | 1.291–1.305 | | |
| | 0.40 | 1.297 | 1.290 | 1.307, 1.323 | 1.305 | 1.290–1.323 | +0.5% [−0.9, +1.6] | +0.4% [−1.4, +2.2] |
| | `2c600dfb` | 1.304 | 1.273 | 1.298, 1.283 | — | 1.273–1.304 | −0.5% [−1.9, +0.5] | |

At the same phase 0.40 reads +0.7%, +0.1%, +0.1% at phase 0; −1.3%, +0.3%,
−0.8% at 16; +1.5%, +2.3%, +1.4% at 32; and +0.2%, −0.1%, +0.5% at 48. Its
slow phase, 32, is where it sits unpadded, and 0.39.0 sits unpadded at 48:
that pairing is the numbers run's +0.7% wall. Averaged over the four phases,
0.40 is +0.2%, +0.7% and +0.4% in the timed section, inside the 1.8–2.7%
that the advance's placement moved on this CPU in
`../2026-11-03-binarytrees/` §5. `e7efe740` (advance inline, before
`19cf3a60`) reads +0.6%, +1.2% and +0.5%. Collections and Σ pause match
0.39.0 (209–216 a run, 100–106 ms). All three sessions drew an EPYC 7763;
no 9V74 came up. On the 9V74 the row read clean at `da2082e1` in keep run
41467319046 (the 2026-11-03 file, §8). The Windows hit path has not changed
since: `da2082e1..2658369a` touches neither `bitmap_alloc.cr` nor
`heap_hot.cr` (`2721f940`'s `heap.cr` change is in `GC_size`).

## Verdict, row by row

| row (numbers run 41577045896, EPYC 7763) | attribution |
|---|---|
| JsonParsePure, timed +7.5%, wall +3.0% | placement. The ranges overlap in 6 of 6 sessions. Wall time at the same phase is 0.6–2.1% faster. On the 7763 the timed section reads +1.5–2.0% pooled, with phase 16 level and phase 48 slow. On the 9V45 it is −2.1% and on the 8573C −0.2%. No commit group carries it, and the checkpoints read level (§1, §3). The collection 0.40 skips is in the setup (§2) |
| Binarytrees, wall +0.7% | placement. The ranges meet, same-phase timed is +0.4% to +0.8% and wall +0.2% to +0.8%, and the slow phase is 32, where unpadded 0.40 sits (§4). It is the inline advance's placement average on the 7763 (`../2026-11-03-binarytrees/`) |

## Files

- `phases.py`: the per-phase tables from a session file or an artifact;
  `--save` writes a trimmed session file.
- `sessions/`: the six sessions' trimmed runs and summaries, and the
  printed tables (`round1-time.txt`, `round1-wall.txt`, `round2-time.txt`,
  `round2-wall.txt`, `round1-trees.txt`).
- `setup-collections.txt`: JsonParsePure's per-collection scan, by tree.
- `probe/`: the workflow as of round 2 (round 1 set `AB_REVS` for the two
  checkpoints and five benches; see the table above), WinBT's `ab.sh`/`ab.py`
  additions, and the five revert patches.
