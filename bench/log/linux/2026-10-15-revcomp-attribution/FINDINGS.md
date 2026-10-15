# Revcomp's 0.35.0 → 0.36.0 drop on Linux: code placement, with counts

Linux x86_64, 12 vCPUs (QEMU guest), Crystal 1.21.0, `-Dgc_none --release`
crystal-metric binaries built from `git archive` of each commit with
`lib/gcry` linked to that tree (`scripts/build.sh`). Every timed or profiled
run held the host-wide lock.

**Answer: placement.** `../2026-10-14-0.36-integration-ab/` read Revcomp at
95% → 92% of Boehm and guessed code placement from Brainfuck's swing. The
counts now back that up:

- 0.36.0 executes **0.14% fewer** instructions on Revcomp than 0.35.0
  (27.639 G against 27.678 G, callgrind).
- gcry's own code (inlined parts included) is **2.8–3.0%** of the
  instructions in every build, 788 M to 822 M. A 34 M-instruction band is
  too narrow to cost the 50–100 ms the integration run saw.
- The collector's work for the run is the same in all four 0.36.0-cycle builds:
  22 collections, 2.1–2.4 ms of total pause, 14 in-place grows.
- **The same gcry source moves Revcomp by 6.2%** (2.019 → 2.144 s) when
  2 096 or 16 bytes of nops sit in front of the program's code. That
  matched in two sessions and is wider than any 0.35.0 → 0.36.0 gap
  measured.

Nothing in gcry needs fixing for this.

## Hardware counters are not available here

The task asked for `perf stat` / `perf record`. Neither works on this host:

- `kernel.perf_event_paranoid` is 4 (Ubuntu's "no unprivileged perf at
  all"), so `perf stat -e task-clock,page-faults true` is refused too.
- `sudo -n true` asks for a password, so the setting can't be lowered.
- The guest has no PMU anyway: `/sys/bus/event_source/devices/` lists
  `breakpoint kprobe msr software tracepoint uprobe`, with no `cpu`. QEMU
  exposes `QEMU Virtual CPU version 2.5+`, so cycles, instructions,
  branch-misses and iTLB/icache events don't exist even for root.

What stands in for them:

- **Callgrind** (`scripts/cg.sh`, valgrind 3.26) gives exact instruction
  counts per function and source file, and *simulated* L1/LL cache misses
  and branch mispredicts.
- **`wait4` rusage** per run gives user/sys time, minor faults and context
  switches (`scripts/ab2.py`).
- **gcry's own heap counters** come from a wrapper that prints them at exit
  (`scripts/stats.cr`).
- **`strace -c -f`** counts syscalls.
- **Placement probes** are binaries that differ only in where code lands.

## 1. Instructions: callgrind, one run per build and bench

`callgrind-summary.md`; raw profiles in `callgrind/*.out.gz`,
`callgrind_annotate`-readable. `GCRY_COLLECT_SCRUB=0` was set in every arm:
the collector's below-SP stack scrub hits valgrind's smaller main stack on
the first `GC.collect` (SEGV in `collect_scrub` → `clear`, which Crystal
reports as "Stack overflow"). The scrub zeroes a few KiB per collection.

| build | Revcomp Ir | gcry Ir | libc Ir | sim. LL misses | sim. mispredicts | Brainfuck Ir |
|---|---:|---:|---:|---:|---:|---:|
| v0.35.0 | 27 677.7 M | 787.6 M | 445.7 M | 61.0 M | 173.3 M | 60 286 M |
| 6dc6e7d0 | 27 659.4 M | 808.1 M | 411.8 M | 54.9 M | 173.4 M | 59 757 M |
| b1cdc0ed | 27 673.1 M | 821.9 M | 410.4 M | 54.8 M | 173.4 M | 59 729 M |
| 48e7c749 | 27 640.4 M | 792.8 M | 410.3 M | 54.8 M | 172.9 M | 59 755 M |
| v0.36.0 | 27 638.9 M | 792.5 M | 409.6 M | 54.7 M | 172.9 M | 59 779 M |

- **gcry Ir** counts instructions whose source line is in `lib/gcry/src`,
  so gcry code inlined into the mutator counts as gcry. 80% of it is
  `Heap#malloc_atomic`, 617 M in 0.35.0 and 623 M in every 0.36.0 build.
- **What moves between 0.36.0 commits** is `stop_world_quiescing_roots` /
  `start_world` (0.3 to 15.7 M). Those are spin-waits whose length depends
  on how valgrind schedules the serialized threads, not work the native run
  does.
- **The back-link** (`49788b15`) left no trace: the large unlinks are 25
  per run, and `index_remove*`/`unlink_chunk` stay under 1.4 M Ir in every
  build, with 0.35.0's the largest.
- **The libc drop** (memcpy, −36 M) and the LL drop (−10%) from 0.35.0 to
  0.36.0 are in-place `realloc` growth: 14 grows, 201 MB not copied.
- **Simulated I1 misses** are under 40 000 in 27–60 G instructions in every
  build, so the hot code fits a 64 KiB I1. Valgrind models no µop cache,
  branch alignment or loop-stream detector, which are the structures
  placement acts on, so it can't show the placement cost itself.
- **Brainfuck** allocates nothing, and gcry is 5–31 M of its 60 G. Its four
  0.36.0 builds execute the same instructions within 0.1% and have the same
  simulated misses. Yet the native wall times are 2.473 s (b1cdc0ed) and
  2.637 s (v0.36.0), 6.6% apart (session 1). So equal work runs at
  different speeds depending on the binary.
- **Brainfuck's 0.35.0 count** is 0.9% higher, all in
  `Hash(Int32, Int32)#[]`. That is the per-process random hash seed, not
  the collector [INFERENCE].

## 2. GC-side counters per build

`gc-counters/`: `stats-<build> Revcomp`, 3 runs each, the default heap's
counters at exit. `strace-<build>.txt` is one `strace -c -f` run of the
timing binary.

| build | collections | total pause | in-place grows (bytes) | large reservations | large recycles | chunk unlinks (walk steps) | mmap / munmap / madvise |
|---|---:|---:|---:|---:|---:|---:|---|
| v0.35.0 | 23 | 2.50–2.68 ms | — | — | 23 | — | 1697 / 698 / 3130 |
| 6dc6e7d0 | 22 | 2.28–2.38 ms | 14 (201 MB) | 15 | 9–14 | — | 1687 / 676 / 3144 |
| b1cdc0ed | 22 | 2.15–2.27 ms | 14 (201 MB) | 15 | 14 | — | 1350 / 785 / 2470 |
| 48e7c749 | 22 | 2.28–2.37 ms | 14 (201 MB) | 15 | 14 | 25 (0) | 1350 / 829 / 2470 |
| v0.36.0 | 22 | 2.10–2.33 ms | 14 (201 MB) | 15 | 14 | 25 (0) | 1350 / 787 / 2470 |

- **Collection time** is about 0.1% of the run in every build. Revcomp's
  heap is atomic strings, so a collection marks almost nothing.
- **The 0.36.0 commits are identical** on collections, grows,
  reservations, total bytes allocated (1 778 986 022) and peak RSS
  (527 MB). `bytes_since_gc` (`135495f5`) changed no collection count.
- **Fewer syscalls on the slower side.** From `b1cdc0ed` on, the run makes
  337 fewer `mmap` and 674 fewer `madvise` calls, and those builds are the
  slower ones in session 1. Minor faults are 282 000 ± 10 in all four
  sessions (286 500 for 0.35.0), and sys time is within 0.01 s.

## 3. Wall time: four interleaved sessions

`tables.md` (medians, IQR, per-rep ratios); raw runs in `ab-*.json`.
`scripts/ab2.py` runs every arm once per (rep, bench) in random order.
"Timed" is the bench's own `in X s`, which covers `run` only. Revcomp builds
its 13 M-nucleotide Fasta input before that, and the setup column is
wall − timed.

| session (reps) | Revcomp v0.35.0 | Revcomp v0.36.0 | ratio per rep, med [IQR] | timed 0.35 → 0.36 | setup 0.35 → 0.36 |
|---|---:|---:|---:|---:|---:|
| 1, five builds (11) | 2.031 s | 2.051 s | 1.011 [1.009, 1.013] | 0.582 → 0.555 s | 1.444 → 1.497 s |
| 2, padding (9) | 2.085 s | 2.108 s | 1.007 [0.997, 1.039] | 0.595 → 0.572 s | — |
| 3, start offset (11) | 2.068 s | 2.077 s | 1.008 [0.997, 1.013] | 0.595 → 0.564 s | — |
| 4, padding again (11) | 2.089 s | 2.089 s | 0.998 [0.990, 1.019] | 0.601 → 0.572 s | — |

- **v0.36.0 is 0–1.1% slower than 0.35.0 per process,** not the 4.6% of
  the integration attribution run. Today's builds come from different paths
  and their placement differs; see §4.
- **Revcomp's own timed section is 4–5% faster in 0.36.0 in every
  session.** That is in-place `realloc` and the memcpy it saves.
- **The extra whole-process time is in the Fasta setup**: +36 ms at
  `b1cdc0ed`, +53 ms at `48e7c749`, with no change in faults, collections
  or instructions.
- **Session 1, per commit:** 2.031 (0.35.0), 2.026 (`6dc6e7d0`), 2.062
  (`b1cdc0ed`), 2.052 (`48e7c749`), 2.051 s (v0.36.0). In the same session
  Brainfuck went 2.564, 2.567, 2.473, 2.618, 2.637 s: it ran 6.6% apart
  across builds that execute the same instructions.

## 4. Placement probe: same gcry, different code addresses

`scripts/main_pad_2096.cr`: v0.36.0's `main.cr` plus one `@[NoInline]`
function whose body is `.skip N, 0x90`, called first so codegen emits it
ahead of what follows. `nm` confirms the hot functions move:
`Revcomp#revcomp`, `Fasta#make_random_fasta` and `Benchmark::run` sit at a
different offset mod 64 from build to build. The program, the collector and
every counter in §2 are unchanged.

| arm | session 2 (9 reps) | session 4 (11 reps) | per-rep ratio to 0.35.0, session 4 |
|---|---:|---:|---:|
| v0.35.0 | 2.085 s | 2.089 s | 1.000 |
| v0.36.0 | 2.108 s | 2.089 s | 0.998 [0.990, 1.019] |
| pad 16 B | 2.115 s | **2.144 s** | 1.030 [1.017, 1.034] |
| pad 80 B | 2.125 s | 2.122 s | 1.024 [1.013, 1.031] |
| pad 2096 B | **2.018 s** | **2.019 s** | 0.970 [0.959, 0.976] |
| pad 0 / 32 / 48 / 112 / 1040 B | 2.065 / 2.108 / 2.100 / 2.083 / 2.060 s | — | — |

- **Pad 2096 is the fastest arm in all 11 reps** of session 4, and pads 16
  and 80 are the two slowest in 7 of them. Sessions 2 and 4 agree within 0.03 s
  on every repeated arm.
- **The spread is 6.2% of Revcomp's whole-process time,** and the timed
  section moves 4.4%, from nothing but where code lands. That covers every
  0.35.0 → 0.36.0 gap measured on this host, yesterday's 4.6% included:
  pad 2096 runs 3% *faster* than 0.35.0, pad 16 3% slower.
- **Brainfuck spreads 7.0% across the pads in session 2.** Session 4 was
  noisier for it (some reps ran 0.2–0.5 s long in every arm), and its order
  there is not stable.
- **Which alignment matters is unknown.** 64-byte phase alone doesn't
  predict it: pads 16, 80 and 1040 put these hot functions at the same
  phases yet read 2.144, 2.122 and 2.060 s. With no PMU, the structure
  responsible (µop cache, branch-target alignment, loop buffer) can't be
  named [INFERENCE].

## 5. Not the large-object start offset

`49788b15` moved a large object from 48 to 64 bytes into its mapping, and
the Windows bisect in the [Unreleased] CHANGELOG leaves data alignment
open. Session 3 (`ab-link.json`, 11 reps) rebuilt v0.36.0 with
`LARGE_LINK_BYTES` 48 and 64 instead of 16 (`scripts/link64.diff`), which
starts large objects at 96 and 112. 112 is 0.35.0's 48 mod 64. The code
doesn't move: the three binaries have the same text size, and `nm` puts
every function at the same address.

Revcomp reads 2.077 / 2.080 / 2.081 s, with the timed section 0.564 /
0.566 / 0.566 s and per-rep ratios 1.000 / 1.001 / 1.000. On Linux the
object's cache-line phase costs nothing measurable.

## What this changes

- **The integration FINDINGS paragraph and the README sentence** now cite
  this directory.
- **The 92% / 95% cells stay as measured** that day.
- **The difference between them is not a collector cost.** It sits within
  the ±3% that code placement alone produces on this host.

Out of scope: Windows, whose timed-section regression the [Unreleased]
CHANGELOG records as open, and macOS. Neither was measured here.

## Files

- `ab-builds.json`, `ab-pad.json`, `ab-link.json`, `ab-pad2.json`: every
  run of sessions 1–4.
- `tables.md`: per-session medians, IQRs and per-rep ratios.
- `callgrind-summary.md`, `callgrind/`: per-build totals, gcry function
  tables, raw `.out.gz` and valgrind's summaries.
- `gc-counters/`: heap counters (3 runs per build) and `strace -c` per
  build.
- `scripts/`: the harness (`ab2.py`), builds, the callgrind and counter
  runners, the counter wrapper, one padding `main` and the start-offset
  diff. The paths are this run's scratch tree.
