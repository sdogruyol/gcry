# Kemal `/json` on `ubuntu-latest`: 0.37's 2–7% is code placement, not collector cost

GitHub `ubuntu-latest` runners (4 vCPUs, image ubuntu-24.04 20261012.601),
Crystal 1.21.0, kemal 1.15.0, `-Dgc_none --release`, `Perf A/B` with
Kemal only: `/json`, `wrk -t2 -c50` 10 s after a 3 s warm-up, 20 trials,
every arm once per trial in random order, a fresh server each time. Six
runs on four CPU models (EPYC 9V74, 9V45 and 7763, Xeon Platinum 8573C).

**Answer: placement.** The ROADMAP item read 0.37 2–7% below 0.36.0 in three
runs and put the step at `a975d5cd`, a commit that removes work. It is where
the program's code lands, not anything the collector does:

- **The same source runs at several speeds.** v0.36.0 rebuilt with 32–2 128
  bytes of nops ahead of all its code spans 0 to −4.5% against itself as
  shipped (EPYC 7763), and v0.37.0 −2.2% to +1.0% in the same run. Across
  both sources a run spans 2.8–5.5 points. v0.37.0 as released reads +1.6%,
  −1.4%, +0.1%, +1.1%, +1.6% and −1.4% against v0.36.0 in six runs: level.
- **The "0.37" those three runs measured was a different layout.** It was
  `4b625c87`'s `src/` (`dab25144`); 0.37.0 added `7a167ddf`, which moves
  every later function by 16 bytes. Rebuilt and timed next to the release,
  `4b625c87` is 2.7%, 2.8% and 1.2% slower than v0.37.0 from source that
  differs by one branch in `collect_stw.cr`.
- **The collector does the same work in every build of one source**: 0.630
  collections per 1 000 requests for v0.36.0 in every arm of every run,
  0.710–0.712 for v0.37.0, and the same 5 964–5 974 bytes allocated per
  request in both. CPU per request is equal within its spread.
- **The code whose placement predicts the speed is the stdlib's JSON and
  HTTP output path, not gcry's.** A class of 15 functions that always move
  together — `JSON::Builder::Escape#write` (15% of the request's
  instructions), `Char#to_s<IO+>` (9%), `IO::Buffered#write`, the
  `HTTP::Headers` hash and `HTTP::Server::Response#write_headers` — explains
  51% of the variance of 66 arm × run effects with 4 groups by its offset mod
  64 (permutation p < 0.0005). At 32 mod 64 it is the slowest placement on
  all four CPUs. gcry's `Heap#malloc` (R² 0.11, p 0.72) and
  `Heap#malloc_atomic` (0.28, p 0.07) don't predict it; two arms built to
  split `malloc_atomic` from the class sided with the class.
- **It explains every earlier measurement.** `a975d5cd`, `272d73e5` and
  `4b625c87` put the class at 32 mod 64. v0.36.0 has it at 16, `fa51f65f` at
  0 and v0.37.0 at 48. The 472 KiB `Heap` pad that "put the layout back"
  moved it from 32 to 48, which is why it read +0.1% to +2.9%.

The real cost of 0.37 here is small and known: 12.7% more collections per
request (`fa51f65f`, the atomic quarter, which buys −10% peak) and a deeper
stack scan (`dab25144`, a soundness fix), together +0.02–0.04 ms of pause
per 1 000 requests, 0.1–0.2% of a request. Nothing in gcry changes (§6).

## Method

`perf-ab.yml` (`bench/runner_ab/ab.sh`, `kemal_ab.py`) gained, for this:

- **Kemal placement probes.** `pads` now builds every probe arm as a Kemal
  server too. `pN` (arm `prepadN`) puts the pad in a prelude ahead of all
  code, gcry's included. `N` (arm `padN`) puts it ahead of `server.cr`'s
  code, which moves Kemal, `HTTP` and `JSON` but not gcry or the prelude's
  code. A leading `b` builds the `base` source that way (`bp16`, arm
  `baseprepad16`), so both revisions' spreads are measured in one run.
- **`benches=-`** skips crystal-metric, and **`kemal_paths`** picks routes
  (`/json` only here).
- **Work per request.** Every Kemal run records the server's user and kernel
  CPU (`wait4`), the requests wrk completed (warm-up and measurement), and,
  on gcry arms, `/gc-stats` read after the measurement. `kemal-summary.md`
  puts them per 1 000 requests. `stats=N` adds N runs of a counter build of
  `base` and `var` (`gc_counters.cr` ahead of `server.cr`; its `GCSTATS` line
  at exit, with the requests served) into `kemal-gc-counters.txt`.
- `syms/` has every Kemal binary's `nm -n`. The probe branch also uploaded
  the binaries, for the layout signatures in §3.

**The layout reproduces locally.** `scripts/kemal_build.sh` builds the server
as `kbuild` does. Its `var`, `base` and `prepad0` put every function at the
runner's address to the byte (`nm` compared; only stdlib path strings in
proc names differ). The builds of the same arm in different runs are
byte-identical (`cmp`). So any revision's placement can be read without a
runner (`phase/builds.md`).

**Runs.** `base` = v0.36.0, `var` = v0.37.0's `src/` (release-0.38.0 at
16b7e67c), 20 trials, `/json`:

| run | round | CPU | arms beyond boehm, base, var |
|---|---|---|---|
| [39384403744](https://github.com/sdogruyol/gcry/actions/runs/39384403744) | 1 | EPYC 9V74 | `p0 p16 p32 p48 p2096 bp0 bp16 bp32 bp48 bp2096`, `stats=3` |
| [39384410102](https://github.com/sdogruyol/gcry/actions/runs/39384410102) | 1 | EPYC 9V45 | same |
| [39384416855](https://github.com/sdogruyol/gcry/actions/runs/39384416855) | 1 | EPYC 7763 | same |
| [39394031539](https://github.com/sdogruyol/gcry/actions/runs/39394031539) | 2 | EPYC 7763 | `tip` (4b625c87), `a975` (a975d5cd), `fa51` (fa51f65f); `16 48 b16 b48 p16` |
| [39394039420](https://github.com/sdogruyol/gcry/actions/runs/39394039420) | 2 | EPYC 7763 | same |
| [39394046979](https://github.com/sdogruyol/gcry/actions/runs/39394046979) | 2 | Xeon 8573C | same |

Probe branch `probe-kemal-pads`: round 1 at `2a260614` (the harness commit
plus binaries in the artifact), round 2 at `9c7d5787` (plus the three extra
revisions as Kemal arms). Deleted after the artifacts were downloaded.

A pad shifts 99.2% of functions (`prepadN`, by N + 32 bytes) or 61–62% of
them (`N`, by N + 32). Ratios are medians of per-trial paired ratios with
their IQR. "Effect" is 100·ln(arm / v0.36.0) per trial, median over trials.

## 1. Same source, several speeds

Each arm against v0.36.0 as shipped, in the same trial (`runs/*/pads.md`):

| arm (code shift) | 9V74 | 9V45 | 7763 |
|---|---:|---:|---:|
| v0.37.0 | +1.6% [−0.9, +1.9] | −1.4% [−2.2, +1.0] | +0.1% [−2.0, +3.2] |
| v0.37.0 +32 | +0.9% | −0.4% | −1.2% |
| v0.37.0 +48 | −1.1% | −2.7% | −2.2% |
| v0.37.0 +64 | +0.6% | −2.1% | −1.9% |
| v0.37.0 +80 | +1.7% | −0.8% | −1.0% |
| v0.37.0 +2 128 | +0.9% | −0.9% | +1.0% |
| v0.36.0 +32 | +1.2% | −0.7% | −1.7% |
| v0.36.0 +48 | −0.1% | −0.5% | −0.3% |
| v0.36.0 +64 | +1.3% | −1.3% | −2.5% |
| v0.36.0 +80 | **−1.0%** | **−3.5%** | **−4.5%** |
| v0.36.0 +2 128 | **−0.3%** | **−2.5%** | **−3.8%** |

- **v0.36.0's own placements span 2.3, 3.5 and 4.5 points**, and v0.37.0's
  2.8, 2.3 and 3.2. Taking both together, a run spans 2.8–5.5 points: the
  2–7% the item recorded between two single builds.
- **Shifts 80 and 2 128 (equal mod 2 048) read alike** for both sources, in
  every run. The placement decides the speed, not noise in one arm.
- Against the mean of all gcry arms in the same trial (`phase/r1-effects.md`,
  bootstrap 95% CIs), v0.36.0 +80 is −1.6% [−2.0, −0.5], −2.3% [−2.7, −0.8]
  and −2.3% [−4.4, −0.2], the slowest arm on every CPU.
- Round 2 repeats it: in three more runs the same-source spreads are 4.2,
  4.5 and 4.2 points, and v0.37.0 reads +1.1% [−0.3, +3.3], +1.6% [−0.7,
  +5.1] and −1.4% [−5.7, −0.3] against v0.36.0.

## 2. The collector does the same work

From `/gc-stats` after each timed run (all arms, all trials), per 1 000
requests served:

| | collections | pause (9V74 / 9V45 / 7763 ×3 / 8573C) | CPU ms (user + sys) |
|---|---:|---|---|
| v0.36.0, every placement | 0.630–0.632 | 0.18 / 0.11 / 0.20, 0.21, 0.20 / 0.17 ms | equal to v0.37.0's within the IQR |
| v0.37.0, every placement | 0.710–0.712 | 0.22 / 0.12 / 0.24, 0.25, 0.23 / 0.20 ms | |

Counter builds (`stats=3`, `runs/*-r1-*/kemal-gc-counters.txt`, 9 runs of
each): 5 964–5 974 bytes allocated per request in both, the same per run to
four digits; 0.629–0.633 against 0.710–0.711 collections per 1 000; heap
22 against 20 MiB; max pause 0.44–0.72 against 0.60–0.75 ms.

- **0.37 collects 12.7% more often per request**, as designed: `fa51f65f`
  counts atomic live bytes a quarter (Boehm's `min_bytes_allocd`), which is
  what takes Kemal's peak 10% lower. `dab25144` scans a running thread with
  no recorded sp from its stack's low-water mark, a soundness fix.
  Together they add 0.017–0.040 ms of pause per 1 000 requests, 17–40 ns on
  a 14–26 µs request: **0.12–0.24%** by run. Round 2 shows `dab25144`'s
  share: `a975d5cd`, which predates it, pauses 0.186–0.220 ms per 1 000 and
  `tip`, which has it, 0.209–0.251 in the same runs (+0.02–0.03).
- **Within one source, collections and pause per request are the same in
  every placement** (e.g. 7763: 0.233–0.238 ms for all six v0.37.0 arms), so
  the 2–5 point spread is the mutator running the same code at a different
  speed.

## 3. Which code: the stdlib's JSON and HTTP output path

The method is `../../windows/2026-10-16-revcomp-attribution/`'s. For each of
the 71 functions that make up 89% of a `/json` request's instructions
(callgrind, §5), `scripts/fn_phases.py` reads every binary's address and a
layout signature: each instruction's mnemonic and length, with branch
targets inside the function as offsets. If a function's placement sets the
speed, then on one CPU model, builds that lay it out the same way at the same
offset mod 64 run at the same speed.

A pad moves every later function by the same amount, so functions fall into
a few classes that group the builds alike. `scripts/phase_joint.py` scores
each class over all 66 (run, build) effects against v0.36.0, grouping within
each CPU model, and shuffles the effects 2 000 times within each model for a
p-value (`phase/joint.md`):

| class (members) | R² | p |
|---|---:|---:|
| **`JSON::Builder::Escape#write`, `Char#to_s<IO+>`, `IO::Buffered#write`, `IO#write_string`, `Int32#to_s<IO+>`, `HTTP::Headers`' hash (`key_hash`, `find_entry`, `[]=`, `entry_matches?`), `HTTP.parse_header`, `Response#write_headers`, … (15)** | **0.51** | **< 0.0005** |
| `JSON::Builder#start_scalar`, `#end_scalar`, `#string`, `#end_object`, … (7) | 0.28 | 0.053 |
| `Gcry::Heap#malloc_atomic` | 0.28 | 0.074 |
| `Heap#mark_impl_unlocked` | 0.24 | 0.14 |
| `Heap#malloc`, `GC.malloc_atomic`, `String::Builder#write_byte`, … (12) | 0.11 | 0.72 |

The leading class's members carry 23.2 k of the 69 k instructions a request
runs (`JSON::Builder::Escape#write` 10.1 k, `Char#to_s` 6.2 k). The
granularity is 64 bytes: grouped by offset mod 32 the class explains 6%.

Mean effect against v0.36.0 by `JSON::Builder::Escape#write`'s offset mod 64:

| CPU | 0 | 16 (v0.36.0) | 32 | 48 (v0.37.0) |
|---|---:|---:|---:|---:|
| EPYC 9V74 | +0.8% (3) | +0.7% (3) | **−0.8% (3)** | +1.1% (3) |
| EPYC 9V45 | −0.8% (3) | −0.5% (3) | **−2.9% (3)** | −1.4% (3) |
| EPYC 7763 | +1.1% (9) | −0.7% (5) | **−1.7% (13)** | −0.2% (5) |
| Xeon 8573C | −0.6% (3) | 0 (1) | **−3.2% (5)** | −1.4% (1) |

**32 mod 64 is the slow placement on all four CPUs**, 1.5–2.5 points below
the others. The other three phases differ less, and not the same way on each
CPU.

**Splitting gcry from the class.** In round 1, `Heap#malloc_atomic` moved
with the class in every arm (its v0.36.0 and v0.37.0 offsets differ by 32 mod
64, as the class's do), so it couldn't be told apart. Round 2's `server.cr`
pads move the class without moving gcry by the same amount: `pad16` puts the
class at 32 (slow) and `malloc_atomic` at 48, and `basepad16` puts the class
at 0 and `malloc_atomic` at 16 (`phase/builds.md`). If `malloc_atomic`
decided it, `pad16` would be the faster of the two. Against v0.36.0, `pad16`
read −0.6%, −0.3% and −3.6%, and `basepad16` −0.8%, +2.7% and −0.2%. Two of
three runs side with the class and one is a tie, and over all runs
`malloc_atomic` stops predicting (p 0.07). That is unlike Windows Revcomp,
whose timed section is `malloc_atomic`-bound.

Which member of the class it is can't be split by moving whole regions: they
are emitted together after `server.cr`'s first code, and every probe moved
them as a block. `Escape#write` (the per-byte loop that escapes each JSON
string) is the largest by far [INFERENCE]. None of it is gcry's code. gcry's
code is emitted earlier (from the prelude), so a gcry change moves the class
by however much gcry's code size changes mod 64. That is how `a975d5cd`,
which shrank the `Heap` and so the displacements in gcry's code, moved it
from 0 to 32.

No hardware counters were read (none on the runners or the QEMU host), so
the front-end mechanism (µop cache lines, branch-target alignment) is not
named [INFERENCE].

## 4. The earlier measurements, read through the class's phase

Class phase = `JSON::Builder::Escape#write`'s offset mod 64 in that build
(`phase/builds.md`; local builds, which match the runners'):

| earlier pair (`../2026-10-18-0.37-runners/`) | CPU | class phase | predicted | measured |
|---|---|---|---|---:|
| 4b625c87 vs v0.36.0, run 1 | 9V45 | 16 → 32 | slower | −2.3% [−3.9, −0.6] |
| 4b625c87 vs v0.36.0, run 2 | 7763 | 16 → 32 | slower | −6.6% [−8.0, −1.6] |
| 4b625c87 vs v0.36.0 | 8573C | 16 → 32 | slower | −2.4% [−4.8, −0.9] |
| 50b1315e vs v0.36.0 | 9V45 | 16 → 0 | ≈ level | −1.2% [−3.8, +0.5] |
| ec551749 vs 50b1315e | 7763 | 0 → 16 | slower | −2.3% [−4.5, +3.2] |
| fa51f65f vs ec551749 | 9V45 | 16 → 0 | ≈ level | +1.6% [−0.6, +3.6] |
| fa51f65f vs v0.36.0 | 7763 | 16 → 0 | faster | +0.4% [−2.4, +4.7] |
| a975d5cd vs fa51f65f (×3) | 9V74, 7763, 9V74 | 0 → 32 | slower | −2.5%, −4.1%, −3.0% |
| 272d73e5 vs a975d5cd | 7763 | 32 → 32 | level | −1.5% [−5.0, +4.3] |
| 4b625c87 vs 272d73e5 | 8573C | 32 → 32 | level | −0.9% [−2.5, +0.2] |
| 4b625c87 vs a975d5cd | 7763 | 32 → 32 | level | +0.2% [−2.4, +3.9] |
| a975d5cd + 472 KiB pad vs a975d5cd (×2) | 7763, 8573C | 32 → 48 | faster | +0.1%, +1.3% |
| 4b625c87 + 472 KiB pad vs 4b625c87 (×2) | 7763, 8370C | 32 → 48 | faster | +2.9%, +2.4% |

Every step lands where the class's phase puts it, or within its IQR. The
bisect found `a975d5cd` because it is the one commit that moved the class
into the slow phase, and the 472 KiB pad "put the layout back" for the code,
not for the data. The step from `4b625c87` to v0.37.0 (`7a167ddf`) moved the
class out of it again: re-timed together in round 2, `a975d5cd` against
`fa51f65f` reads −2.8% [−4.4, −0.2], −4.1% [−5.8, −1.3] and −1.7% [−5.5,
+0.8], and `4b625c87` against v0.37.0 −2.7%, −2.8% and −1.2%.

**The `Heap` data layout is not it.** `a975d5cd` moved 288 of the `Heap`'s
647 fields (the ones after the old arrays), and 46 of them to another offset
mod 64 (`scripts/heap_ivars.cr`). Between v0.36.0 and v0.37.0, 580 of the
647 fields changed offset mod 64. Yet v0.37.0 and v0.36.0 run level, and the
class's code phase alone predicts every pair above.

## 5. Instructions per request (callgrind, here)

`scripts/cg_kemal.sh`: one server under callgrind, instrumentation switched
on after a 10 s warm-up, 30 s of `wrk -t1 -c10` on `/json`, Ir divided by
wrk's request count (`callgrind/`):

| build | Ir / request | stdlib, Kemal, libc | gcry | `GC::` shims |
|---|---:|---:|---:|---:|
| v0.36.0 | 68 173 | 56 000 | 9 164 | 3 009 |
| v0.37.0 | 70 329 | 56 011 | 11 310 | 3 008 |

- **The request's own path is the same code** in both: 56 000 against
  56 011 Ir, and gcry's allocation paths are unchanged too (`Heap#malloc`
  3 580, `Heap#malloc_atomic` 3 221 Ir per request in both).
- The +2 146 Ir of gcry's collection path (mark +663, the stop and restart
  of the world +593, fiber and pthread stack scan +354, `stack_low_water`
  +266) is inflated under valgrind, which runs one thread at a time: the
  stop's waits spin on threads that aren't scheduled [INFERENCE]. On the
  runners, where it is measured in time, the whole collection difference is
  0.017–0.040 ms per 1 000 requests (§2).

## 6. A fix?

None, and none is needed in gcry:

- **The code that decides it isn't gcry's.** It is Crystal's `JSON`, `IO`
  and `HTTP` code, emitted after gcry. Its phase depends on the size mod 64
  of everything emitted before it: gcry, Kemal, the application, the Crystal
  version. A pad in gcry tuned to put it at a fast phase for this benchmark
  on this compiler would be lost by the next change to any of those, and
  would favour one app's layout over another's. That is benchmark tuning,
  not a sound or deterministic fix.
- **Crystal can't align a function or a loop.** There is no annotation for
  it, and no `-mllvm` passthrough (`crystal build --help`: `--mcpu`,
  `--mattr`, `--mcmodel` only). An `asm(".p2align 6")` inside a function
  would only align what follows within that function, and it is stdlib
  code, not gcry's.
- **`@[AlwaysInline]`/`@[NoInline]` in gcry move code around without pinning
  anything**: an inlined fast path takes its caller's placement.

So no default changes and no five-runner A/B is needed. Kemal A/Bs of a
few percent on `ubuntu-latest` should be read with `pads` (e.g. `-f
pads="p0 p16 p32 p48 bp0 bp16 bp32 bp48"`): a gap inside the same-source
spread is placement.

## Files

- `runs/<id>-r<round>-<cpu>/`: `kemal-runs.json` (every run: req/s, peak,
  CPU, faults, requests, `/gc-stats`), `kemal-summary.md`, `pads.md`
  (`scripts/kemal_pads.py`: per arm the code shift, req/s against Boehm,
  `base` and `var`, and work per request; hot functions' offsets mod 64),
  and in round 1 `kemal-gc-counters.txt`.
- `phase/`: `r1-phases.json` and `r2-phases.json` (`scripts/fn_phases.py`:
  each hot function's address, size and layout signature in every runner
  binary), `r1-effects.md`/`.json` (`scripts/effects.py`), `r1-classes.md`
  (`scripts/phase_classes.py`, round 1 only), `joint.md`
  (`scripts/phase_joint.py`, all six runs) and `builds.md` (the class's and
  gcry's offsets in every revision measured here or in the bisect).
- `callgrind/`: both profiles (`*.cg.gz`, `callgrind_annotate`-readable),
  wrk's counts and `ir-per-request.tsv`/`summary.txt`
  (`scripts/cg_per_request.py`).
- `scripts/kemal_build.sh` (a runner-identical Kemal build of any revision,
  optionally padded), `heap_ivars.cr` (the `Heap`'s field offsets).
