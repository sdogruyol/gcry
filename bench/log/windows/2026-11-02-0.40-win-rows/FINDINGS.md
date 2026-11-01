# Windows rows of 0.40 against 0.39.0: placement, row by row (2026-11-02)

The numbers run (Perf A/B 41253485376, `../2026-11-01-0.40-runners/`) left
six Windows rows slower than 0.39.0 with one pad a side: JsonParsePure,
JsonParseSerializable, JsonParsePull and JsonGenerate (wall +2.0–2.9%, both
0.40 arms above both 0.39.0 arms in the first three), Primes (+6.3% wall,
2–3% slower at equal collection counts) and Revcomp (+7.3% wall), plus
RegexDna (+1.4%). The JSON rows and RegexDna were called placement by the
keep-rule session with two pads a side (41248448693), marked [INFERENCE] in
the numbers file. This file settles each row in same-session runs on
`windows-latest` alone.

**Verdict: every row is code placement.** With all four 16-byte phases of
both trees in one session, 0.40 and 0.39.0 read the same time at the same
phase (same-phase medians −2.3% to +3.3% apart, both signs, under 0.5% on
RegexDna and the control), each row's 0.40 range overlaps 0.39.0's in
timed section and in wall time, on two CPU models, and no default-path
commit reverted on its own moves a row out of the tip's band. Unpadded,
0.40 lands on a slow phase of every one of these rows and 0.39.0 on a fast
one, which is what the numbers run measured. Nothing in the tree changes.

Method: `perf-ab`'s `bench/runner_ab/ab.sh`, run by a push-triggered probe
workflow on `windows-latest` (`probe-win-rows.yml`, deleted with its
branches; it and the probe-only `AB_REVS` in `ab.sh` are kept at the tags
below), Crystal 1.21.0, 21 interleaved reps per arm (31 in §3's Primes
sessions), no Boehm arm. `var` = the 0.40 tip `07b61d28`, `base` =
`v0.39.0`. `prepadN`/`baseprepadN` are the trees with N bytes of nops ahead
of all their code (`ab.sh`, `prep`). `AB_REVS` added arms built from other
revisions' `src/`, padded the same way (`revpN`). The control row,
Fannkuchredux, works on stack arrays: 3 collections a run, 0.03 ms of
marking. Raw: `raw/` (per-session `summary.md`, the placement and Primes
sessions' `runs.json`, `phases.txt`, `phases-wall.txt`, `revert-bands.md`);
`bands.py` and `phases.py` print the tables below from a session's artifact
(`phases.py` reads the artifact's `syms/` link maps).

| run | branch tip (tag) | sessions (runner CPU) |
|---|---|---|
| 41287063366 | `51019dcf` (`archive/probe/win-rows-1`) | placement (EPYC 7763); one revert each: unroll (Xeon 8573C), freeing (EPYC 7763), counters (EPYC 7763), idle (EPYC 9V45), reserve (Xeon 6973P-C), staging (Xeon 8573C) |
| 41287513572 | `c39aef28` (`archive/probe/win-rows-2`) | layout (Xeon 6973P-C) |
| 41291927022 | `effe0e7d` (`archive/probe/win-rows-3`) | placement2, placement4 (EPYC 9V74), placement3 (EPYC 7763) |
| 41292084433 | `58593a6c` (`archive/probe/win-rows-4`) | regexdna1, regexdna2 (EPYC 9V74) |
| 41296503120 | `d760a971` (`archive/probe/win-rows-5`) | primes-unroll1 (EPYC 9V45), primes-unroll2, primes-unroll3 (EPYC 7763), 31 reps (§3) |

The 0.40 numbers run was an EPYC 7763 (`../2026-11-01-0.40-runners/`), as
are `placement` and `placement3`.

## 1. Four phases of each tree, one session

Each arm's timed-section median (s) at the phase its code lands on, read
from the link maps as `Revcomp#revcomp`'s address mod 64. A prepad moves
all of a tree's code by the same amount, and between the trees 1 230 of the
1 350 non-gcry functions both link (91%) move by the same amount mod 64 as
`revcomp` (0x1e70, ≡ 48), `JSON::Lexer#next_token`,
`JSON::PullParser#read_next` and `JSON::Builder::Escape#write` among them;
gcry's own functions move by every multiple of 16. Unpadded, 0.40 is at 32
and 0.39.0 at 48.
`placement`, EPYC 7763, 0.40 / 0.39.0:

| bench | phase 0 | 16 | 32 | 48 | 0.40 range | 0.39.0 range |
|---|---|---|---|---|---|---|
| Primes | 1.442 / 1.443 | 1.423 / 1.351 | 1.471, 1.462 / 1.460 | 1.447 / 1.417, 1.410 | 1.423–1.471 | 1.351–1.460 |
| JsonParsePure | 0.862 / 0.852 | 0.832 / 0.838 | 0.854, 0.858 / 0.850 | 0.829 / 0.820, 0.827 | 0.829–0.862 | 0.820–0.852 |
| JsonParseSerializable | 0.739 / 0.735 | 0.695 / 0.699 | 0.731, 0.732 / 0.730 | 0.691 / 0.690, 0.688 | 0.691–0.739 | 0.688–0.735 |
| JsonParsePull | 0.731 / 0.712 | 0.683 / 0.690 | 0.715, 0.713 / 0.723 | 0.676 / 0.672, 0.676 | 0.676–0.731 | 0.672–0.723 |
| JsonGenerate | 1.283 / 1.286 | 1.288 / 1.292 | 1.375, 1.371 / 1.373 | 1.348 / 1.345, 1.359 | 1.283–1.375 | 1.286–1.373 |
| Revcomp | 1.384 / 1.387 | 1.263 / 1.264 | 1.505, 1.503 / 1.468 | 1.301 / 1.265, 1.259 | 1.263–1.505 | 1.259–1.468 |
| Fannkuchredux | 2.648 / 2.650 | 2.734 / 2.727 | 2.632, 2.623 / 2.632 | 2.637 / 2.641, 2.640 | 2.623–2.734 | 2.632–2.727 |

(Two medians in a cell: the tree's unpadded arm and its arm padded by 48,
which lands at the same phase 64 bytes on; 16 bytes of nops move the code
32, 32 move it 48.) Wall time, same session, 0.40 against 0.39.0 ranges:
JsonParsePure 1.851–1.900 against 1.850–1.900, JsonParseSerializable
1.859–1.922 against 1.864–1.929, JsonParsePull 1.846–1.920 against
1.853–1.928, JsonGenerate 3.110–3.198 against 3.080–3.215, Primes
1.492–1.540 against 1.418–1.531, Revcomp 3.798–4.046 against 3.751–3.997
(`raw/phases-wall.txt`).

- **The JSON parse rows** have two placements, 3.5–6% apart: phases 0 and
  32 slow, 16 and 48 fast, in both trees (JsonParseSerializable 0.730–0.739
  against 0.688–0.699). 0.40 unpadded is at 32, 0.39.0 at 48: the numbers
  run's +4.0–5.5% timed. At the same phase the two trees read −1.4% to
  +1.2% apart, except JsonParsePull at 0 (+2.7%).
- **JsonGenerate**: 0 and 16 fast, 32 and 48 slow, ~7% apart; same-phase
  differences −0.8% to +0.2%.
- **Revcomp** follows `revcomp`'s offset in both trees, as the keep-rule
  file found with two pads (`../../linux/2026-11-01-0.40-keep-rule/` §2): 16
  and 48 fast (1.26–1.30 s), 0 at 1.38, 32 at 1.47–1.51, a 19% band. At 0
  and 16 the trees read the same to 0.003 s; at 32 and 48 0.40 is 2.4–3.3%
  slower here and −1.8% to +2.0% in the other four sessions (below).
- **Primes**: §3.
- **Fannkuchredux** moves 4% with placement too (phase 16 slow in both).

The same in the other three placement sessions (`raw/phases.txt`;
`placement3` on an EPYC 7763, `placement2` and `placement4` on an EPYC
9V74): every row's ranges overlap, in timed section and wall time, and
same-phase medians are −2.3% to +3.3% apart, Primes aside (§3); the widest
is JsonParsePure in `placement4`, +3.3% at 0 (0.714 against 0.691) and
−2.0%, −2.3% at 32. Revcomp's band on the 9V74 is 1.04–1.23 s, 18% wide,
with the same order of phases; `placement3` reads `placement`'s Revcomp
medians to 0.011 s.

## 2. RegexDna

Two sessions of RegexDna, Revcomp and the control (EPYC 9V74,
`regexdna1`, `regexdna2`): RegexDna reads 2.809–2.856 s for 0.40 against
2.812–2.857 for 0.39.0, every same-phase pair within 0.5%; phases 0 and 32
are 1.4% slower than 16 and 48 in both trees, and 0.40 unpadded is at 32,
0.39.0 at 48 — the numbers run's +0.7% timed, +1.4% wall.

## 3. Primes: placement, and the pace's tenth collection

Primes collects 9 or 10 times; the tenth costs 7–10% of the timed section
(`placement`: 0.39.0 unpadded 1.325 s at 9 against 1.422 at 10). At equal
counts the trees read the same per phase: at 10 collections 0.40's arms are
1.423–1.472 s and 0.39.0's 1.422–1.478 (`placement`), 1.208–1.220 against
1.215–1.234 (`placement2`), 1.531–1.583 against 1.517–1.572 (`placement3`).
The tenth comes more often with 0.40, in all four placement sessions, but at
a rate placement moves for both trees:

| session | 0.40 arms at 10 (var, p16, p32, p48, p64) | 0.39.0 arms at 10 (base, bp16, bp32, bp48, bp64) |
|---|---|---|
| placement (EPYC 7763) | 19, 17, 17, 19, 18 of 21 | 13, 0, 16, 8, 16 of 21 |
| placement3 (EPYC 7763) | 17, 18, 12, 17, 18 | 7, 1, 13, 8, 13 |
| placement2 (EPYC 9V74) | 19, 20, 21, 20, 19 | 17, 5, 13, 17, 20 |
| placement4 (EPYC 9V74) | 5, 9, 5, 6, 11 | 3, 3, 6, 4, 2 |

The step is the pace's (ROADMAP, "The pace prices the next cycle at the
last one's cost"; `../../macos/2026-11-01-primes-collections/`): whether
the seventh major lands under ~300 MiB live depends on the fifth cycle's
mark against its stretch, which placement and the session move. The
unroll (`cbf1b2e8`) makes the mark cheaper, so a probe with it reverted
(`archive/probe/keep-040-unroll`) went into three Primes-only sessions, 31
reps, 0.40, 0.39.0 and the tip less the unroll, each unpadded and padded by
16, 32 and 48 bytes (0.40 and the probe at phases 32, 0, 16, 32; 0.39.0 at
48, 16, 32, 48). Runs at 10 collections, summed over the four arms (of 124):

| session | 0.40 | tip less unroll | 0.39.0 | timed-section medians: 0.40 / less unroll / 0.39.0 |
|---|---:|---:|---:|---|
| primes-unroll1 (EPYC 9V45) | 19 | 16 | 13 | 0.826–0.866 / 0.826–0.835 / 0.838–0.846 |
| primes-unroll2 (EPYC 7763) | 39 | 23 | 10 | 1.356–1.412 / 1.384–1.392 / 1.364–1.390 |
| primes-unroll3 (EPYC 7763) | 59 | 38 | 25 | 1.308–1.376 / 1.320–1.367 / 1.306–1.320 |

On the 7763 the tip without the unroll reaches the tenth collection about
halfway between 0.40 and 0.39.0, and each tree's count still moves with
placement (the tip less the unroll: 4 and 6 of 31 at phase 32, 18 at phase 0 in
`primes-unroll3`). [INFERENCE] The cheaper mark lowers the paced threshold
toward the step, as for arm64 JsonGenerate's fifteenth collection
(`../../linux/2026-11-01-0.40-keep-rule/` §4); the rest is placement of the
cycle's cost. Primes' time ranges overlap in all three sessions. This is the
open pacing item, not a Windows cost; nothing here changes the pace.

## 4. One commit at a time

One session per default-path commit (`git log v0.39.0..07b61d28 -- src`),
each the tip and the tip less that commit unpadded and padded by 16, 32 and
48 bytes (0.40 at phases 32, 0, 16, 32; the probes where their own link maps
put them) plus
unpadded 0.39.0. The reverts: `cbf1b2e8` (mark unroll,
`archive/probe/keep-040-unroll`), `6aa84284` + `e3a2de7a` (FREEING and the
`occ` load, `-freeing`), `f18e9c17` alone (large-cache counters atomic,
`archive/probe/win-rows-counters`), `435b3511` (idle baseline, `-idle`),
`b4a707f4` (long reservation front; its new branch is `unless win32`,
`-reserve`), `b209b395` alone (staging counter, `archive/probe/win-rows-staging`).
`2c600dfb`, `bf607374` and the Darwin heap commits compile to nothing here
on 1.21.0 (keep-rule file, intro). Timed-section medians, 0.40 range / tip
less the commit range / 0.39.0 (`raw/revert-bands.md`):

| session (CPU) | Primes | JsonParsePure | JsonParseSerializable | JsonParsePull | JsonGenerate | Fannkuchredux |
|---|---|---|---|---|---|---|
| unroll (Xeon 8573C) | 1.528–1.543 / 1.538–1.549 / 1.544 | 0.879–0.896 / 0.900–0.911 / 0.866 | 0.676–0.711 / 0.676–0.711 / 0.671 | 0.660–0.696 / 0.664–0.700 / 0.649 | 1.241–1.361 / 1.232–1.356 / 1.352 | 2.958–3.041 / 2.963–3.037 / 2.983 |
| freeing (EPYC 7763) | 1.470–1.511 / 1.491–1.497 / 1.439 | 0.826–0.860 / 0.816–0.850 / 0.825 | 0.695–0.733 / 0.682–0.730 / 0.701 | 0.685–0.721 / 0.669–0.718 / 0.688 | 1.282–1.380 / 1.281–1.378 / 1.342 | 2.624–2.730 / 2.630–2.644 / 2.638 |
| counters (EPYC 7763) | 1.381–1.409 / 1.386–1.415 / 1.378 | 0.816–0.858 / 0.820–0.834 / 0.838 | 0.690–0.733 / 0.698–0.713 / 0.682 | 0.679–0.725 / 0.693–0.703 / 0.674 | 1.284–1.377 / 1.282–1.372 / 1.336 | 2.626–2.728 / 2.630–2.729 / 2.655 |
| idle (EPYC 9V45) | 1.017–1.032 / 0.991–1.003 / 1.016 | 0.547–0.556 / 0.557–0.568 / 0.551 | 0.387–0.394 / 0.382–0.398 / 0.381 | 0.380–0.392 / 0.374–0.389 / 0.378 | 0.743–0.767 / 0.740–0.752 / 0.746 | 2.302–2.359 / 2.313–2.360 / 2.306 |
| reserve (Xeon 6973P-C) | 1.155–1.199 / 1.149–1.204 / 1.203 | 0.665–0.679 / 0.673–0.686 / 0.661 | 0.524–0.535 / 0.529–0.533 / 0.523 | 0.509–0.518 / 0.513–0.516 / 0.510 | 0.954–1.037 / 0.953–1.046 / 1.052 | 2.197–2.246 / 2.188–2.220 / 2.193 |
| staging (Xeon 8573C) | 1.600–1.611 / 1.599–1.623 / 1.615 | 0.896–0.906 / 0.891–0.904 / 0.875 | 0.683–0.717 / 0.686–0.716 / 0.673 | 0.663–0.702 / 0.667–0.703 / 0.658 | 1.256–1.373 / 1.252–1.373 / 1.364 | 2.987–3.071 / 2.990–3.065 / 3.013 |

No revert brings a row's band under the tip's. Three bands do not overlap,
each in a direction no cost of the reverted commit explains: on the 9V45
the tip less `435b3511` runs Primes faster than the tip at all four
placements (0.991–1.003 against 1.017–1.032 s), while 0.39.0, which has the
same idle code, reads the tip's time (1.016 s; every arm at 9 collections in
20 or 21 of 21 runs), and runs JsonParsePure slower (0.557–0.568 against
0.547–0.556). On the 8573C the tip less the unroll reads JsonParsePure
slower (0.900–0.911 against 0.879–0.896). Removing one commit moves every
function after it, and with them the relative layout that padding all code
by the same amount does not vary.

A layout session (Xeon 6973P-C, 41287513572) also ran 0.39.0 with the 32
bytes of `Heap` fields `6aa84284` adds (`cursor_free_deferrals`,
`bitmap_free_split_hook`, `bitmap_free_claim_guard`, unused;
`archive/probe/win-rows-layout`), so 0.39.0's code reads 0.40's heap field
offsets (`+0x20` past them, checked in the Windows disassembly). Its four
placements' range overlaps both trees' on every row (`raw/revert-bands.md`,
`# layout`); the one arm far out, the probe padded by 32 on JsonParsePure
(0.796 s against 0.664–0.702 for every arm of both trees), is slower than
0.40 as well. The heap layout is not the cost either.

## 5. What the 0.40 hit path executes on Windows

`hit-path.txt`: crystal-metric cross-compiled for
`x86_64-windows-msvc` from both trees (Crystal 1.21.0, `--release
-Dgc_none`), disassembled with `llvm-objdump`. The allocation fast path
(`Heap#malloc`, `#malloc_atomic`, with `cursor_advance_word` inlined) differs
in the word advance only, once per 64 blocks: one more stack reload per
word scanned, and before a word is claimed a plain `movl` of the chunk's
flags and a `testl $0x1000` (FREEING). The acquire fence emits no
instruction and the relaxed `occ` load is the same `movq` as before. Code
is LLVM's on Windows as on Linux (the MSVC toolchain links; it does not
compile). FREEING's two locked RMWs (`lock orl`/`lock andl` on the chunk
flags) are in `GC.free_impl` only: an explicit `GC.free`, which Crystal
1.21's standard library calls from zlib's and GMP's free hooks and none of
these benches reach. The large-cache counters' compare-and-swap loops are
in the large paths (`alloc_large_counted`, `grow_large`, `map_chunk`):
JsonParsePure makes 12 large reservations a run
(`../2026-11-01-0.40-runners/x86-gc-counters.txt`).

## Verdict, row by row

| row (numbers run, wall) | attribution |
|---|---|
| JsonParsePure +2.0% | placement: phases 0/32 slow, 16/48 fast in both trees, 0.40 at 32 and 0.39.0 at 48 (§1) |
| JsonParseSerializable +2.9% | the same, 6% between the placements (§1) |
| JsonParsePull +2.5% | the same (§1) |
| JsonGenerate +2.5% | placement: 32/48 slow, 0/16 fast, 7% (§1) |
| Revcomp +7.3% | placement: `Revcomp#revcomp` at 32 mod 64, a 16–19% band whose order of phases both trees share (§1) |
| RegexDna +1.4% | placement: 0/32 1.4% slower in both trees (§2) |
| Primes +6.3% | placement at equal collections (§3); 0.40 reaches the pace's tenth collection more often, about half of that with the mark unroll on the 7763 ([INFERENCE] its cheaper mark), at a rate placement moves for both trees (0.39.0: 0 to 20 of 21 runs) (§3) |

No commit carries a row (§4), and the hit path's added work is one load and
one test per 64 blocks (§5). Nothing to fix; no default-path change, so no
keep-rule run.
