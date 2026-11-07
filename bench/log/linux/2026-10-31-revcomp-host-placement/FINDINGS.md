# Revcomp's 1–2% in 0.39.0 on the Linux host: where the allocation entry lands (2026-10-31)

ROADMAP item from `../2026-10-24-0.39-linux-host/` ("The clean session"):
Revcomp read 1–2% slower in 0.39.0 than in 0.38.0 in three sessions, with the
16- and 64-byte pad arms of the two trees not overlapping; on `ubuntu-latest`
a 16-byte pad of 0.38.0 covered it (`../2026-10-22-0.39-keep-rule/`, Round 3).

**Answer: code placement, of one function.** `GC::malloc_atomic`, the
allocation entry with gcry's hit path inlined (6.59 M calls per Revcomp run),
starts at an address ≡ 0 mod 64 in the v0.38.0 binary and ≡ 16 mod 64 in the
v0.39.0 binary, and on x86-64 Revcomp is slowest with that function at ≡ 16,
whichever tree it is built from. Commit `9e89fddc` (the mprotect re-arm fix)
moved it there: its five new class variables (`@@mp_inflight`, `@@mp_gen`,
`@@mp_unsafe_frees` and two `@[ThreadLocal]`s) are initialized in
`__crystal_main`, which grew 18 832 → 18 912 bytes, and `GC::malloc_atomic`
is emitted right after it (`0x1b340` → `0x1b390`). Averaged over eight
placements of each tree, 0.39.0 is level with 0.38.0 on this host (+0.05%
[−0.38, +0.23]) and faster on both Linux runners (−0.92% on `ubuntu-latest`,
−0.45% on arm64). The collector does the same work in both releases, and
0.39.0 executes 0.12% more instructions, all from `e508db25` (the slow-path
tail call) — a ~0.1–0.2% cost that cannot be told from noise on any runner.
Nothing to fix.

Builds: `-Dgc_none --release` crystal-metric from this branch's
`bench/crystal_metric`, gcry `src/` from `git archive <rev>`
(`scripts/build.sh`); placement arms put N bytes of nops ahead of all the
program's code, as perf-ab's `pN` (`--prelude`). Crystal 1.21.0, the 12-vCPU
QEMU host (no PMU, `perf_event_paranoid` 4). Every local timing, build and
callgrind run held `heavy.lock`.

## 1. GitHub runners (primary evidence)

`perf-ab.yml` from `revcomp-host-040` (`80d23a9d`: v0.39.0's src plus the
1.22.1 compat gate, which changes nothing on the runner's Crystal 1.21.0),
`base` = v0.38.0 (`9157672e`), Revcomp + Brainfuck, 15 reps, no Boehm arm,
`pads="p16 p32 p48 p2096 bp16 bp32 bp48 bp2096"`: five placements per tree in
one interleaved session. `scripts/rnpool.py` reads `runs.json` and `syms/`.

**`ubuntu-latest`, run 41212029709** (`runner-41212029709-ubuntu-latest/`):

| arm | wall | timed | wall vs base, paired | `GC::malloc_atomic` mod 64 |
|---|---:|---:|---:|---:|
| var + p48 | 4.251 | 1.478 | −1.1% [−1.5, −0.8] | 32 |
| var + p2096 | 4.252 | 1.476 | −1.1% [−1.7, −1.0] | 32 |
| base + p32 | 4.284 | 1.496 | −0.5% [−0.7, −0.1] | 0 |
| **base (v0.38.0)** | 4.299 | 1.515 | — | **0** |
| var + p16 | 4.307 | 1.481 | +0.1% [−0.4, +0.4] | 0 |
| base + p16 | 4.318 | 1.540 | +0.4% [+0.0, +0.7] | 48 |
| **var (0.39)** | 4.351 | 1.562 | **+1.2% [+0.9, +1.4]** | **16** |
| var + p32 | 4.357 | 1.565 | +1.2% [+0.6, +1.5] | 16 |
| base + p48 | 4.396 | 1.580 | +2.2% [+1.9, +2.5] | 16 |
| base + p2096 | 4.400 | 1.578 | +2.3% [+2.0, +2.5] | 16 |

- The four arms at ≡ 16 are the four slowest, two of each tree; 0.38.0 at
  ≡ 16 is slower than 0.39 at ≡ 16. At ≡ 0, 0.39 + p16 reads what 0.38.0
  does (+0.1%).
- Pooled over the five placements per rep: 0.39 **−0.92% [−1.07, −0.72]**
  wall, −1.91% timed section. Arm medians: 0.38.0 4.284–4.400 s, 0.39
  4.251–4.357 s.
- Brainfuck (allocates nothing): arms spread 4.976–5.167 s (3.8%), pooled
  −0.15% [−1.71, +2.31].

**`ubuntu-24.04-arm`, run 41213664006** (`runner-41213664006-ubuntu-24.04-arm/`,
with 3 counter runs per side): no regression to explain. Unpadded 0.39
+0.3% [−0.3, +0.5]; pooled **−0.45% [−0.53, −0.24]** wall, −1.17% timed;
arm medians 3.244–3.255 s (0.38.0) and 3.225–3.254 s (0.39). No phase effect
(AArch64 code is 4-byte aligned; the phases spread over 8–60). GC counters
equal: 27–28 collections, 14 in-place grows, 15 reservations on both sides.
Brainfuck pooled −2.82% [−3.62, −0.29], arms 3.792–3.945 s.

## 2. Local sessions on the host

`sN-runs.json` (whole-process wall and the bench's own `in N.NNNs`, "timed";
setup = wall − timed is Revcomp's Fasta input), `sN-summary.txt`
(`scripts/an.py`, `padpool.py`, `phase.py`), `sN-load.txt` (load average
every 30 s). These ran before the runner sessions above, under the lock but
next to other agents' unlocked work; no `ps` snapshot was taken, so what
besides the desktop was busy is not recorded. The load column is all there
is: s2 is too noisy to read and is kept only for completeness.

| session | load | arms | Revcomp result |
|---|---|---|---|
| s1, 11 reps | 3.2–9.6 | v038/v039 × pads 0/16/64, v039 with `GCRY_SLOW_ENTRY_WIPE=0`, with `GCRY_FOUR_GIB_FENCE=0` | v039 +1.5% [+0.3, +3.3]; neither knob recovers it (2.234, 2.260 s against 2.244); the three ≡ 16 arms (v039 and its two env arms) are the slowest |
| s2, 11 reps | 5.1–13.6 | v038, 7 commits, v039, p64 of both | unreadable (IQRs to +20%) |
| s3, 11 reps | 1.6–4.9 | v038/v039 × pads 0/16/32/48/64/80/1040/2096 | pooled −0.16% [−0.52, +0.10]; arms 2.086–2.180 s (0.38.0), 2.093–2.146 s (0.39); the three slowest arms by timed section are ≡ 16, the fourth ≡ 16 arm is fifth |
| s4, 13 reps | 1.2–3.9 | s3's 16 arms + 7 commits unpadded | pooled **+0.05% [−0.38, +0.23]** (per-rep min −0.50, max +0.40); unpadded pair 2.027 → 2.051 s (+1.4% [+0.7, +2.0]) |

s4's timed section by phase of `GC::malloc_atomic` (median s):

| mod 64 | arms |
|---|---|
| 0 | v038p32 0.564, **v038 0.570**, v039p1040 0.580, v039p16 0.582, v039p80 0.582 |
| 16 | c15 0.574, c12 0.582, c18 0.586, v039p32 0.588, c31 0.590, **v039 0.595**, c25 0.596, c29 0.599, v038p48 0.611, v038p2096 0.614, c24 0.624 |
| 32 | v039p2096 0.560, v038p64 0.563, v039p48 0.564 |
| 48 | v038p1040 0.565, v038p80 0.567, v038p16 0.570, v039p64 0.574 |

The phase is a proxy: what decides is where the hit path's hot blocks fall
inside the function, which shifts a little between commits (c15's ≡ 16 reads
0.574, c24's 0.624). Why ≡ 16 costs (a hot loop or branch target across a
32- or 64-byte fetch line, µop-cache ways) can't be named without hardware
counters [INFERENCE]. 0.38.0 itself is slow at ≡ 16 (p48, p2096) on the host
and on `ubuntu-latest`, so the effect is the phase and not 0.39's code.

The commits, unpadded, in s4 (wall s): v038 2.027, c12 2.099, c15 2.024, c18
2.038, c24 2.090, c25 2.047, c29 2.051, c31 2.047, v039 2.051 — all inside
the placement band (2.005–2.110 s over the 16 pad arms), no step at any
commit (c12 = `5d9898d1`, c15 = `1a56f792`, c18 = `2954eb83`, c24 =
`ee35803e`, c25 = `ef14b84b`, c29 = `48971e09`, c31 = `f23c99af`). Every
build from `9e89fddc` on has `GC::malloc_atomic` at `…390`, ≡ 16
(`syms/`); `a04ce52a`, the commit before it, still at `0x1b340`, ≡ 0 (built
for the symbol table only).

## 3. What the collector does: the same

`gc-counters-revcomp.txt`: 5 runs each of counter builds (`gc_counters.cr`
hook) of v0.38.0 and v0.39.0, with `/usr/bin/time`. Both: 27–28 collections,
3.1–4.5 ms total pause, 14 in-place grows (201 MB), 15 large reservations,
1 778 986 022 bytes allocated, 283 470–283 570 minor faults, 538–541 MB max
RSS, user 1.96–2.06 s. 0.39's 4 GiB fence placed one fence in one of five
runs (`four_gib_fences=1`, `four_gib_remaps=1`), none in the others.

## 4. Instructions: callgrind

`callgrind/`: one run per build with `GCRY_COLLECT_SCRUB=0` (valgrind's main
stack; see `../2026-10-15-revcomp-attribution/`), cache and branch
simulation.

| build | Ir | I1 misses | LL read / write misses | sim. mispredicts |
|---|---:|---:|---:|---:|
| v0.38.0 | 27 549.97 M | 40 204 | 26.22 M / 28.51 M | 176.75 M |
| c12 `5d9898d1` | 27 548.89 M | 41 939 | 26.21 M / 28.50 M | 174.91 M |
| c15 `1a56f792` | 27 582.26 M | 38 591 | 26.18 M / 28.49 M | 176.49 M |
| v0.39.0 | 27 582.77 M | 42 006 | 26.20 M / 28.50 M | 177.18 M |

- **+32.8 M instructions (+0.12%) from 0.38.0 to 0.39.0, all at
  `e508db25`** (the slow path's tail call and stack wipe), between c12 and
  c15. They are in the inlined hit path of `GC::malloc_atomic`, about five
  per call over 6.59 M calls (`scripts/cgdiff.py`, `cglines.py`). The
  disassembly (`c12-malloc_atomic.s`, `c15-malloc_atomic.s`) shows why: with
  the slow path a tail call `allocate_entry(self, size, …)`, LLVM keeps the
  heap and the size in `%rdi`/`%rsi`, which the out-of-line
  `Heap::tls_cursor_cache` call clobbers, so both are stored to the frame
  before it and loaded back after (`mov %rsi,0x18(%rsp)`, `mov
  %rdi,0x10(%rsp)`, two reloads and a `lea`); before, they lived in `%r14`
  and `%rbx`. The wipe itself (`allocate_wipe`, `Roots.wipe_below_sp`) is
  2.5 M instructions on the slow path.
- At this host's ~12.5 G instructions/s that is about 3 ms of 2.05 s,
  ~0.15% [INFERENCE]: below every spread here, and the pooled runner results
  read 0.39 faster.
- Cache and branch simulation are level (LL misses within 0.1%,
  mispredicts within 1.3%, I1 misses ~40 000 everywhere). Valgrind models no
  fetch alignment, which is where the measured difference is.

## Not the other candidates

- **Slow-path stack wipe:** `GCRY_SLOW_ENTRY_WIPE=0` on v0.39.0 (s1) is as
  slow as v0.39.0. The knob keeps the tail calls, whose spill is the five
  hit-path instructions above; the wipe itself is 2.5 M on the slow path.
- **4 GiB fence:** `GCRY_FOUR_GIB_FENCE=0` (s1) the same; 0–1 fences a run.
- **Atomic shared counters:** written per mapping, unmapping, revival or
  `GC.free`, not per allocation, and no locked instruction was added to
  `GC::malloc_atomic` (both disassemblies have the same six).
- **Mark batch loop:** total pause 3–4.5 ms of a 2 s run in both releases.
- **Large `realloc` growth:** same 14 in-place grows, no moves, in both.

## Verdict

Placement. The unpadded v0.39.0 binary happens to start its allocation
entry at the phase where Revcomp runs slowest on x86-64; the same holds for
v0.38.0 padded there. Over eight placements locally and five on each Linux
runner, 0.39.0 is level with or faster than 0.38.0. The README's +2.0% for
Revcomp is that one placement. Nothing in gcry changes; the five-instruction
spill `e508db25` added to the hit path is recorded here as the only real
cost found, too small to measure.

Open [INFERENCE]: the next change to `__crystal_main`'s size (any new
class variable or constant initializer in gcry or the program) moves
`GC::malloc_atomic` again, and Revcomp with it, by up to ~2% on x86-64.
Pinning the entry's alignment would need a function alignment Crystal does
not expose (`-mllvm -align-all-functions=6` is the program's build flag,
not the shard's). `release-0.40.0` at `16d7112d` (large-cache counters and
the macOS high heap merged) still builds it at `0x1c390`, ≡ 16
(`syms/r040-16d7112d.txt`), so a 0.40.0 Linux table built from it starts
from the same phase as 0.39.0's.

## Files

- `scripts/build.sh`, `buildall.sh`: the builds (one lock hold each).
  `session.sh` runs `ab.py` (`../2026-10-14-rss-budget-recheck/ab.py` plus
  the timed section and `AB_SEED`; Revcomp's `err` line, Boehm's too, is not
  a failure) under the lock with a load sampler. `stats.sh`: counter builds
  under `/usr/bin/time`. `cg.sh`: callgrind.
- `scripts/an.py`, `padpool.py`, `phase.py`: the local tables;
  `rnpool.py`: the runner tables; `cgdiff.py`, `cglines.py`: callgrind
  per function and per source line.
- `syms/`: `__crystal_main`, `GC::malloc_atomic` and the bench's own
  functions from `nm -n` of every local build (`c9` = `a04ce52a`, `c10` =
  `9e89fddc` added for the bisect of the address).
