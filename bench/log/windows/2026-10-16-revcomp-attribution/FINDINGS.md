# Windows Revcomp's 0.35.0 → 0.36.0 drop: code placement of gcry's allocation path

GitHub `windows-latest` runners (4 vCPUs, 16 GiB, Windows Server 2025), Crystal
1.21.0 MSVC, `--release`, `Perf A/B` dispatched on probe branches. Nine
runs, 15 interleaved reps each. The runner's CPU differs between runs (Intel
Xeon 8573C and 8370C, AMD EPYC 7763, 9V45 and 9V74), so each run is
compared only with itself.

**Answer: placement.** `../2026-10-15-0.36-native/` measured Revcomp's timed
section +7.7% [+7.1, +10.0] slower in 0.36.0 than in 0.35.0 and left the
cause open. It is where code lands, not what the collector does:

- **The same v0.36.0 source runs in two speeds.** It was rebuilt with 0–2 096
  bytes of nops ahead of *all* the program's code. On an EPYC 7763, three
  placements run Revcomp's timed section in 1.254–1.270 s, as fast as 0.35.0
  or faster (−1.5% to +0.1%). The other seven run it in 1.409–1.476 s, 11–13%
  slower. Two sessions sorted the ten builds into the same two groups, and
  v0.36.0 as shipped is in the slow one.
- **0.35.0 does the same:** 1.280 s to 1.489 s across its own ten
  placements, +16.3%.
- **The collector does the same work in every build:** 22 collections, 14
  in-place grows (201 MB), 15 large reservations, 0 reserve failures, the
  same 1 778 913 286 bytes allocated, 7–13 ms of total pause. 0.36.0 takes
  11% fewer page faults than 0.35.0 (346 k against 391 k) and the same
  kernel time.
- **The code whose placement decides it is gcry's own:** `Gcry::Heap#malloc_atomic`,
  the small-object allocation path, or `Heap#allocate` behind it. On
  Revcomp's timed path, no other function's offset mod 64 is consistent
  with all 61 builds timed on three CPU models. Every stdlib function on
  the path, `String#tr` and `IO::Memory#write` included, is ruled out. The
  same rule predicted the 0.37.0 tip's placement probes before they ran: 5
  of 5 arms, on two CPUs.
- **Data alignment is not it.** Starting large objects at 0.35.0's phase
  mod 64 instead of the back-link's changes the timed section by −0.4%
  [−1.0, +0.5].

No collector cost to fix, Windows-specific or not: Windows does fewer
large-chunk `VirtualAlloc`/`VirtualFree` bytes in 0.36.0, not more (§3).
The release-0.37.0 tip (`4fcee559`) is 7.5–13.1% faster than v0.36.0 on the
same runners, because its placement happens to be a fast one (§5).

## Method

`perf-ab.yml` gained three things for this, all on `bench/runner_ab/`:

- **`pads`: placement probes.** One arm per count, each the dispatched ref's
  source built with that many bytes of nops in a never-inlined function
  called once. Crystal emits a function where codegen first reaches a call
  to it, so code emitted after the pad moves by the pad, rounded to the next
  16-byte function start. Nothing else changes. There are two kinds:
  - `N` (arm `padN`) calls the pad first in `main.cr`, which is the
    mechanism `../../linux/2026-10-15-revcomp-attribution/` used. It moves the benchmarks and the
    stdlib code they are first to reach, but not the collector. gcry's
    allocation paths are emitted while codegen walks the prelude, before
    `main.cr` (link map: `__placement_pad` at RVA 0xa9f80, `Heap#malloc_atomic`
    at 0x519f0).
  - `pN` (arm `prepadN`) calls it from a prelude that requires the stock one
    after it (`--prelude ./pad_prelude`). Only 4 public functions come
    before it in the binary, so everything after it moves, gcry included.

  On MSVC, `.skip` is LLVM's assembler directive. A release build is one
  `.text` section, and link.exe keeps it in order. In the runners' link
  maps (`/MAP`, written for every Windows build into the artifact's `syms/`),
  1 750 of the 1 751 functions after the pad moved by exactly the pad's
  shift, and the 4 before it stayed put.
- **`stats`:** a counter build (`gc_counters.cr`) of `base` and `var` prints
  the default heap's counters at exit, N runs per bench.
- **Per-run CPU and faults:** `utime`/`stime` from `GetProcessTimes` and
  `faults` from `PageFaultCount` on Windows (`wait4` rusage elsewhere).

Benches were Revcomp and Brainfuck. Brainfuck allocates nothing, so it serves
as a placement control. "Time" is the bench's own timed section, the cell
the 0.36-native table flagged. Ratios are medians of per-rep paired ratios
with their IQR. Medians, IQRs and per-rep ratios for every arm are in
`tables.md`. Raw runs, counters and the hot functions' addresses per binary
are in `runs/<run id>-<what>-<cpu>/`.

| run | runner CPU | source (`var`) | `base` | arms |
|---|---|---|---|---|
| [38890029106](https://github.com/sdogruyol/gcry/actions/runs/38890029106) | Xeon 8573C | v0.36.0 | v0.35.0 | `pad` 0 16 32 48 80 112 1040 2096 |
| [38890037632](https://github.com/sdogruyol/gcry/actions/runs/38890037632) | EPYC 9V45 | v0.36.0 | v0.35.0 | same |
| [38895043370](https://github.com/sdogruyol/gcry/actions/runs/38895043370) | EPYC 7763 | v0.36.0 | v0.35.0 | `prepad` 0 16 32 48 64 80 112 1040 2096 |
| [38895050587](https://github.com/sdogruyol/gcry/actions/runs/38895050587) | EPYC 7763 | v0.36.0 | v0.35.0 | same |
| [38895057939](https://github.com/sdogruyol/gcry/actions/runs/38895057939) | EPYC 7763 | v0.35.0 | v0.36.0 | same |
| [38890224933](https://github.com/sdogruyol/gcry/actions/runs/38890224933) | EPYC 9V74 | v0.36.0, `LARGE_LINK_BYTES = 64` | v0.36.0 | — |
| [38890076811](https://github.com/sdogruyol/gcry/actions/runs/38890076811) | EPYC 7763 | `4fcee559` (0.37.0 tip) | v0.36.0 | `pad` 16 80 2096 |
| [38901835522](https://github.com/sdogruyol/gcry/actions/runs/38901835522) | Xeon 8370C | `4fcee559` | v0.36.0 | `prepad` 0 16 32 48 |
| [38901844942](https://github.com/sdogruyol/gcry/actions/runs/38901844942) | EPYC 7763 | `4fcee559` | v0.36.0 | same |

Probe branches: `probe-win-revcomp-036` (`aabcbea5`, and `c8c77734` for the
first two runs: `src/` = v0.36.0), `probe-win-revcomp-035` (`de3feb8c`,
`src/` = v0.35.0), `probe-win-revcomp-link64` (`0764f89b`) and
`probe-win-revcomp-037` (`96548cd9`, then `4dabf154`: `src/` = `4fcee559`).
All were deleted once the artifacts were downloaded. The first four runs
(38890029106, 38890037632, 38890076811, 38890224933) used the harness before
prelude pads and full symbol tables were added, so their `syms/` lists only
the benchmarks' functions. The final harness (`8d48d9c4`, branch
`probe-win-revcomp-harness`, deleted) also ran on `ubuntu-latest` and
`macos-latest` (38906743819: 1 rep of Brainfuck, `pads="16 p16"`,
`stats=1`). Every arm built, ran, and wrote its counters and symbol table.

## 1. Same source, two speeds

Revcomp's timed section. Each arm against 0.35.0 in the same run:

| arm (bytes of nops before all code) | v0.36.0, s1 (38895043370) | v0.36.0, s2 (38895050587) |
|---|---:|---:|
| v0.35.0 | 1.284 s | 1.267 s |
| v0.36.0 as released | 1.476 s, +12.4% | 1.420 s, +12.6% |
| prepad 0 | **1.270 s, −0.8%** | **1.254 s, −1.5%** |
| prepad 16 | 1.431 s, +11.2% | 1.409 s, +11.3% |
| prepad 32 | **1.265 s, −1.3%** | **1.254 s, −1.3%** |
| prepad 48 | 1.455 s, +11.7% | 1.424 s, +12.4% |
| prepad 64 | **1.268 s, −0.9%** | **1.268 s, +0.1%** |
| prepad 80 | 1.453 s, +13.0% | 1.417 s, +12.1% |
| prepad 112 | 1.429 s, +11.5% | 1.420 s, +12.2% |
| prepad 1040 | 1.433 s, +12.2% | 1.414 s, +11.6% |
| prepad 2096 | 1.434 s, +11.7% | 1.422 s, +12.3% |

- **The ten builds fall into two groups, the same in both sessions.** The
  pad function plus the 16-byte rounding shifts everything after it by 16,
  32, 48, … bytes. The fast builds are those shifted 16 mod 32 from the
  release. Whole-process wall follows: −0.7 to −2.0% against 0.35.0 for the
  fast three, +3.0 to +4.3% for the slow seven.
- **Same-source spread: +16.7% and +13.6%**, against the +7.7% being
  explained. Fast v0.36.0 beats 0.35.0, as on Linux, where Revcomp's timed
  section is 4–5% faster from in-place `realloc` growth.
- **User time carries it:** 3.56–3.63 s for the fast builds against
  3.75–3.84 s for the slow ones (s1). Kernel time is 0.20–0.27 s and faults
  346.4–346.6 k in every v0.36.0 build.
- **Brainfuck moves 5.4–5.5%** across the same builds, in a different order.

0.35.0 rebuilt the same way (38895057939, v0.36.0 as `base` at 1.434 s):
1.287 s as released, then 1.406, 1.355, 1.489, 1.281, 1.402, 1.370, 1.280,
1.347 and 1.291 s for prepads 0 to 2096. That is four levels by shift mod 64,
1.280 s to 1.489 s (+16.3%). Release 0.35.0 happens to sit in its fastest
group.

### Moving only the benchmarks' code doesn't do it

The Linux probe's `main.cr` pad (38890029106 on a Xeon 8573C, 38890037632 on
an EPYC 9V45) leaves gcry where it is. On the Xeon every v0.36.0 build stays
slow: +9.4% to +13.7% against 0.35.0, with a same-source spread of 3.4%
(1.528–1.580 s against 1.402 s). On the 9V45 the builds read +2.8% to +9.6%
(spread 5.9%; v0.36.0 itself +5.9%). Brainfuck moves 7.6% and 14.6% across
those builds, so the pad does move code. It just isn't the code that
decides Revcomp. That is the first sign that the deciding code is emitted
before `main.cr`, where gcry's allocation paths are.

## 2. The collector does the same work

`gc-counters.txt` per run. Revcomp, the default heap's counters at exit,
2–3 runs of each build per dispatch:

| build (runs) | collections | total pause | in-place grows | large reservations (failures) | large chunk unlinks (walk steps) | bytes allocated | bytes unmapped |
|---|---:|---:|---:|---:|---:|---:|---:|
| v0.35.0 (6) | 22–23 | 6.9–13.4 ms | — | — | — | 1 979 977 944 | 1.15–1.26 GB |
| v0.36.0 (15) | 22 | 6.9–12.9 ms | 14 (201 MB) | 15, 64 MiB (0) | 7–9 (0) | 1 778 913 286 | 0.95–1.08 GB |
| `4fcee559` (7) | 22 | 8.6–11.6 ms | 14 (201 MB) | 15, 64 MiB (0) | 8–9 (0) | 1 778 913 286 | 0.95–1.08 GB |
| link64 probe (2) | 22 | 8.0–8.2 ms | 14 (201 MB) | 15, 64 MiB (0) | 7–8 (0) | 1 778 913 286 | 1.01–1.08 GB |

- **Every 0.36-cycle build does identical work.** The collector's total
  pause is under 1% of a 1.3–1.5 s timed section in every build.
- **Per run, 0.36.0's faults are 346.4–346.6 k in every build of every run,
  0.35.0's 391.3 k.** In-place growth leaves 200 MB uncopied, and 11% fewer
  pages are touched. Kernel time is the same within each run (e.g. 0.19 and
  0.19 s, 0.25 and 0.23 s).

## 3. The Windows large-chunk path costs nothing here

The suspects were `VirtualAlloc`/`VirtualFree` per large chunk, the
back-link's extra commit, and `MEM_RESERVE` tails held until the chunk is
released.

- **0.36.0 maps and unmaps fewer bytes than 0.35.0:** 0.95–1.08 GB unmapped
  against 1.15–1.26 GB. In-place growth commits a grown block's tail in its
  own reservation (`os_commit`) instead of mapping a new block and freeing
  the old.
- **The back-link adds no commit.** It sits 32 bytes into the mapping, on
  the page the header already commits.
- **The reservations are 15 per run, 64 MiB of address space in total,** all
  granted. A tail is reserved, never committed, so it is neither faulted nor
  charged. Releasing it only with the chunk costs address space, not time.
- **Kernel time and faults don't rise in any slow build** (§1), so there is
  no OS cost for the drop to hide in.

### Not data alignment either

`probe-win-revcomp-link64` is v0.36.0 with `LARGE_LINK_BYTES = 64`, so a
large object starts 112 bytes into its mapping, 0.35.0's 48 mod 64. Against
v0.36.0 on the same EPYC 9V74 runner (38890224933): timed section −0.4%
[−1.0, +0.5], wall +0.2%, Brainfuck −0.1%. The probe changes no code
placement that matters: `malloc_atomic` sits at the same offset in both
(`phase/obj-phases.txt`), and both ran in the 9V74's slow group, 1.198 and
1.202 s, where `b1cdc0ed` and `bfe05bd3` ran 1.054 and 1.087 s. Linux found
the same (`../../linux/2026-10-15-revcomp-attribution/` §5).

## 4. Which code: gcry's `Heap#malloc_atomic`

**The runner's layout can be reproduced on Linux.** `crystal build -Dgc_none
--release --cross-compile --target x86_64-pc-windows-msvc` writes the
object link.exe gets on the runner. All 1 421 functions of v0.36.0's object
sit at the offsets the runner's link map gives for its binary, so phases
can be computed for any commit without a runner (`scripts/phase.sh`,
`scripts/obj_phase.py`, output in `phase/`).

**Method.** A function can be what decides the speed only if its placement
explains every build. For each function in every build,
`scripts/phase_consistency.py` takes the layout signature (each
instruction's mnemonic and length, and branch targets inside the function,
so a build that only renumbers a constant lays the function out the same)
and the offset mod 64. A function is ruled out if two builds on the same CPU
model share both yet ran at different speeds. The 7763's classes are
fast < 1.33 s ≤ mid < 1.38 s ≤ slow (0.35.0's placements have a middle
level), the 9V74's fast < 1.12 s and the 8370C's fast < 1.35 s. Placement-probe
arms take their source's code and their addresses from the runner's link
map, and unpadded builds the object's offsets. The commit-by-commit A/B of
`../2026-10-15-0.36-native/` adds six builds: its runs were on EPYC 7763s
(`123069c3`, `0a0e3165`, `f2f25ea2`, `135495f5`) and 9V74s (`bfe05bd3`,
`b1cdc0ed`).

- **EPYC 7763, 49 builds** (the three prepad runs, the tip's prepads in
  38901844942, the tip and v0.36.0 in 38890076811, and the four A/B commits):
  10 of 1 139 functions survive. On Revcomp's timed path only
  `Gcry::Heap#malloc_atomic` and `Gcry::Heap#allocate` (its refill path) do.
  `String#tr`, `String#chomp`, `String#size`, `Revcomp#revcomp`,
  `IO::Memory#write`, `IO::Memory@IO#write_string`, `Slice#[]` and
  `GC_malloc_atomic` are each contradicted 35–204 times (`phase/epyc7763.txt`).
- **EPYC 9V74, 6 builds** (`bfe05bd3` and `b1cdc0ed` with their v0.36.0
  arms, and the link64 run) and **Xeon 8370C, 6 builds** (the tip's prepads
  in 38901835522). These rule out less on their own (959 and 309 survive),
  but the 10 survive both (`phase/epyc9v74.txt`, `phase/xeon8370c.txt`).
  Six of the ten run at most a few dozen times per process: `inspect`
  methods, `Heap::new`, `run_collection_body` (22 collections),
  `GC::realloc_impl` (~25 buffer growths) and two `Char`/`Unicode`
  predicates. That leaves gcry's `Heap#malloc`, `Heap#malloc_atomic` and
  `Heap#allocate`, and Revcomp's timed section allocates its strings
  through the last two.
- **Fit:** across the 33 arms of the three prepad runs, grouping arms by one
  64-byte phase of the program's code explains 89% of the variance in
  Revcomp's timed section (R² 0.894, `phase/fit-r2.txt`).

`malloc_atomic` is the allocation behind each of the ~4.3 M strings the
timed section makes: 2.17 M lines from `each_line`, and as many 60-byte
slices of the reversed sequence. On Linux, callgrind put 80% of gcry's
instructions in it (`../../linux/2026-10-15-revcomp-attribution/`).

**The commit-by-commit A/B, read through its phase.**
`phase/obj-phases.txt` gives each build's `malloc_atomic` offset. Its layout
changes twice between the releases, at `123069c3` and at `135495f5`:

| build | `malloc_atomic` layout | offset mod 64 | timed section (CPU) |
|---|---|---:|---|
| v0.35.0 | `7756014c` | 16 | fast (7763, 9V45) |
| `123069c3` | `51a8ab17` | 48 | mid, 1.334 s (7763) |
| `bfe05bd3` | `51a8ab17` | 16 | fast, 1.087 s (9V74) |
| `0a0e3165` | `51a8ab17` | **32** | **slow, 1.477 s (7763)** |
| `f2f25ea2` | `51a8ab17` | 48 | mid, 1.351 s (7763) |
| `135495f5` | `2e277b44` | 0 | fast, 1.279 s (7763) |
| `b1cdc0ed` | `2e277b44` | 16 | fast, 1.054 s (9V74) |
| `49788b15` = v0.36.0 | `2e277b44` | **48** | **slow, 1.42–1.48 s (7763), 1.19–1.20 s (9V74)** |
| `4fcee559` (0.37.0 tip) | `2e277b44` | 32 | fast (7763, Xeon 8370C; §5) |

The back-link commit `49788b15` shrank the gcry code emitted ahead of
`malloc_atomic` by 1 120 bytes, moving it from 16 to 48 mod 64. The step to
`0a0e3165` ("live_objects free fix, invariant births, a Heap field and a
branch in `counters_atomic?`") grew it by 1 488, moving it from 16 to 32.
That is the ±12% "between builds that share Revcomp's code": they share
Revcomp's code, not gcry's placement.

Which phase is slow depends on the CPU. For layout `2e277b44`, offsets 0
and 32 are fast on the 7763 and 16 and 48 are slow. On the 9V74, 16 was fast
(`b1cdc0ed`). Which front-end structure is responsible (µop cache lines,
branch-target alignment, the loop buffer) can't be named: no hardware
counters were read on the runners (not attempted), and Crystal has no way
to align a function or a loop [INFERENCE].

## 5. The 0.37.0 tip, and a prediction

`4fcee559` (release-0.37.0's tip: v0.36.0 plus the batched serial mark and
the 1.22 compat gate) against v0.36.0:

- **38890076811, EPYC 7763:** 1.255 s against 1.418 s, −11.6% [−12.1, −10.9],
  wall −4.2%. The `main.cr` pads 16, 80 and 2096 read −9.0%, −8.4% and
  −11.5%. Brainfuck +1.9%. The counters match v0.36.0's (§2). The mark change
  can't account for this: the whole collection pause is ~10 ms. What it does
  is change gcry's code size ahead of `malloc_atomic` (+0x5f0 bytes, moving
  it from 48 to 32 mod 64) while the stdlib code moves by 0 mod 32.
- **Prediction, written from §4 before 38901835522 and 38901844942 ran:** on
  the 7763, `malloc_atomic` at 0 or 32 mod 64 is fast and at 16 or 48 slow.
  So the tip's prepads 0, 16, 32, 48 (shifts +16, +32, +48, +64: phases 48,
  0, 16, 32) should read slow, fast, slow, fast, with the tip itself fast.

| arm (`malloc_atomic` mod 64) | predicted | Xeon 8370C (38901835522) | EPYC 7763 (38901844942) |
|---|---|---:|---:|
| v0.36.0 (48) | slow | 1.402 s | 1.467 s |
| tip (32) | fast | **1.311 s, −7.5%** | **1.294 s, −13.1%** |
| tip prepad 0 (48) | slow | 1.417 s, −1.1% | 1.444 s, −1.9% |
| tip prepad 16 (0) | fast | **1.310 s, −7.3%** | **1.316 s, −10.1%** |
| tip prepad 32 (16) | slow | 1.387 s, −1.1% | 1.392 s, −5.0% |
| tip prepad 48 (32) | fast | **1.320 s, −6.7%** | **1.290 s, −12.5%** |

All five arms land where predicted, on both CPUs. The Intel 8370C follows
the same split as the 7763.

**So the tip's gain over v0.36.0 is placement too.** It isn't banked: the
next change to gcry's code ahead of `malloc_atomic` can flip Windows Revcomp
by ±10% in either direction, as `0a0e3165` and `49788b15` did between 0.35.0
and 0.36.0.

## What this changes

- `../2026-10-15-0.36-native/FINDINGS.md`: Revcomp's cause is code placement
  of gcry's allocation path (this directory). The 95% cell and the +7.7% stay
  as measured.
- CHANGELOG `[Unreleased]`, ROADMAP and `docs/WINDOWS.md` no longer call it
  open.
- No collector change. A fix would be making `malloc_atomic`
  placement-insensitive, which needs function or loop alignment control that
  Crystal doesn't expose [INFERENCE].
- Reading Windows (and Linux) A/Bs of a few percent on allocation-heavy rows:
  a `-f pads="p0 p16 p32 p48"` dispatch shows the placement spread on the
  runner itself.

## Files

- `runs/<id>-<what>-<cpu>/`: `runs.json` (every run, with `utime`, `stime`,
  `faults`), `summary.md`, `gc-counters.txt` (where `stats` was on), and
  `syms-hot.txt` (the timed path's functions per binary, from the runner's
  link map, by `scripts/hot_syms.py`). The full maps are in each run's
  `perf-ab-windows-latest` artifact (30-day retention).
- `tables.md`: every run's per-arm medians, IQRs and paired ratios
  (`scripts/tables.py`).
- `phase/`: cross-compiled offsets (`obj-phases.txt`), the consistency
  results on each CPU, and the R² fit.
- `scripts/`: `tables.py`, `hot_syms.py`, `phase_fit.py`, `objlayout.py`,
  `obj_phase.py`, `phase_consistency.py`, and `phase.sh`, which rebuilds the
  objects and regenerates `phase/` from downloaded artifacts.
