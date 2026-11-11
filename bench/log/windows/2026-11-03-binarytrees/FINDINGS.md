# Windows Binarytrees on the 0.40 tip: the out-of-line word advance on EPYC 9V74 (2026-11-03)

The keep rule on the 0.40 tip `2c6a3aa4` (Perf A/B 41409560598, against
`v0.39.0`, `bench/log/linux/2026-11-01-0.40-keep-rule/keep.py`) left one row
unexcused: windows-latest Binarytrees, time +3.4% [+2.4, +5.2], wall +4.8%
[+3.0, +5.8], var-code arms 1.086 / 1.075 / 1.076 s against base-code
1.045 / 1.042 / 1.046. The earlier keep runs read the row clean. Candidates
named: `23a78cd9` (the pre-scan scrub, inside the pause, `OS.clear_dead_stack`
on Windows), `21462240` (the pthread scan clamp), `e2737a33` (the band wipe),
`19cf3a60` (hot fields first, word advance out of line), the pace commits.

**Answer: `19cf3a60`'s out-of-line word advance (`Heap#cursor_advance_word`,
`@[NoInline]`), on the EPYC 9V74 Windows runners only.** On that CPU the tip
reads 3–5% slower than 0.39.0 at every placement, the src history steps up at
`19cf3a60` and nowhere else, and the tip with the advance inline again (hot
fields kept first) reads level with 0.39.0. The pre-scan scrub, the band
wipe, every collector scrub and the clamp change nothing: Σ pause is the same
in every arm, and the pre-scan scrub costs ~0.3 ms of a run (~1.5 µs a
collection). The row was clean before because no earlier keep run drew a
9V74: 41248448693 and 41331393029 ran on EPYC 7763, ScrubBand's 41336539784
and CI21b's 41378845352 on Xeon 8573C; 41409560598 was the first on a 9V74
(the job logs' `Machine` step). On the EPYC 7763 the out-of-line advance is
1.8–2.7% faster than 0.39.0 averaged over placements, and on ubuntu-latest
on the same 9V74 it costs nothing. **Fix: the advance is inline on x86-64
Windows only** (`bitmap_alloc.cr`); every other target keeps it out of line,
its codegen unchanged. The keep rule passes on the fix in six runs, the
five runners once and windows-latest five times more, a 9V74 among them
(41467319046: the row clean).

Method: `perf-ab`'s `bench/runner_ab/ab.sh`, run by a push-triggered probe
workflow (`probe/probe-winbt.yml`, the last round's; deleted with its branch
`probe/winbt`), Crystal 1.21.0, `base` = `v0.39.0` (`c0d570c5`), `var` = the
tip `2c6a3aa4`, Binarytrees only (nine benches in round 5), 25 interleaved
reps (15 in round 5), no Boehm arm. Arms beyond the pads
(`probe/ab-probe.patch`): `AB_REVERTS` (the tip with commits reverted,
`rv_*`), `AB_PATCHES` (the tip with a patch, `pt_*`: `probe/knob.patch`,
`inline.patch`, `lastfields.patch`), `AB_ENVARMS` (a built arm's binary
under extra environment) and `AB_REVS` (another
revision's `src/`); a `_p16`/`_p64` suffix is that arm prepadded. `ab.py`
also sums each phase of the `collect_end` trace over a run (Σ pause, Σ
stacks phase). Rounds 2 and 3 skipped any runner that was not a 9V74 after
reading its CPU. `sessions/` holds each session's summary and its runs
(trimmed to time, wall, user, collections, Σ mark, Σ pause, Σ stacks);
`tab.py` prints a session's per-arm table.

| round | run | probe tip | arms | sessions (CPU) |
|---|---|---|---|---|
| 1 | 41429880126 | `693d32bb` | pads p16 p64 bp16 bp64; `rv_prescan` (−`2c6a3aa4` −`23a78cd9`) unpadded, p16, p64; `rv_clamp` (−`21462240`); `pt_knob` and `knob_off` (`GCRY_MUTATOR_SCAN_SCRUB=0`, same binary); `nowipe` (`GCRY_COLLECT_BAND_WIPE=0`); `noscrub` (`GCRY_COLLECT_SCRUB=0`) | s1 s2 s4 (EPYC 7763), s3 s5 s6 (9V74) |
| 2 | 41433002522 | `a3963bbb` | pads p16 bp16; nine `src` checkpoints `v0.39.0`..tip, each unpadded and p16 | w1 w6 w9 (9V74) |
| 3 | 41437353530 | `9dc307e3` | pads p16 p64 bp16 bp64; `rv_hot` (−`19cf3a60`), `pt_inline`, `pt_lastfields`, each unpadded, p16, p64 | w2 w3 w5 (9V74) |
| 4 | 41440734704 | `492f2962` | pads p16 p64 bp16 bp64; `pt_inline` unpadded, p16, p64 | w1–w5 (EPYC 7763), w6 (9V45), m1–m3 (macos-15-intel, i7-8700B) |
| 5 | 41445195510 | `99cb8cf0` | as round 4, nine benches, 15 reps | u1 u2 (ubuntu-latest, 9V74), a1 (arm64), ml1 (M1), mi1 (i7-8700B), w1 (9V74), w2 (7763) |

## 1. The flagged row's pauses (41409560598, `stats=3`)

The counter builds (`gc-counters.txt`), per run:

| arm | collections | Σ pause, ms | per collection, µs | max pause, ms |
|---|---|---|---|---|
| base | 211, 206, 206 | 84.8, 84.4, 68.7 | 402, 410, 334 | 4.10, 4.34, 4.21 |
| var | 198, 192, 215 | 74.5, 71.0, 73.2 | 376, 370, 340 | 4.22, 4.39, 4.27 |

No extra pause: ~170 µs more a collection would have been ~37 ms more Σ
pause. The timed section's 41 ms is the mutator's (user time +4.8%); Σ mark
is 33 → 37 ms, inside the pads' 34.6–38.1.

## 2. Round 1: the recent collector commits, reverted or off

Binarytrees, timed section; first column var against base, then each arm
against var (paired per rep, median [IQR]); Σ pause var / base; Σ stacks
phase var / `rv_prescan` / `knob_off` (ms per run):

| session | CPU | var vs base | rv_prescan | knob_off | nowipe | noscrub | rv_clamp | Σ pause | Σ stacks |
|---|---|---|---|---|---|---|---|---|---|
| s1 | 7763 | −0.8% [−1.9, −0.5] | −0.2% [−1.3, +1.5] | +0.5% [−0.7, +1.5] | +0.1% [−0.9, +0.6] | +0.0% [−1.5, +1.0] | +0.3% [−1.2, +2.0] | 103.3 / 106.6 | 6.15 / 5.85 / 5.96 |
| s2 | 7763 | −2.0% [−3.3, −0.2] | +0.2% [−1.7, +1.2] | +0.0% [−1.5, +0.8] | +0.2% [−1.9, +1.8] | −0.1% [−1.2, +1.3] | +0.0% [−1.6, +1.3] | 104.4 / 99.5 | 6.28 / 5.90 / 5.92 |
| s4 | 7763 | −1.4% [−2.6, −1.1] | +0.3% [−0.6, +1.0] | +1.0% [−0.3, +2.0] | +0.2% [−1.2, +1.0] | +0.1% [−0.7, +1.1] | +1.0% [−0.5, +1.4] | 95.9 / 101.4 | 6.33 / 5.90 / 5.89 |
| s3 | 9V74 | +5.2% [+2.1, +8.0] | +0.1% [−1.3, +2.3] | −1.0% [−3.2, +1.0] | −0.6% [−5.2, +1.2] | −0.2% [−3.6, +2.2] | −0.2% [−2.4, +1.4] | 82.3 / 83.2 | 4.98 / 4.63 / 4.65 |
| s5 | 9V74 | +4.6% [+2.2, +5.2] | +0.2% [−1.1, +1.8] | +0.3% [−1.1, +2.1] | −0.5% [−1.3, +1.7] | +0.7% [−1.6, +3.3] | −0.1% [−0.9, +1.2] | 83.6 / 83.4 | 4.98 / 4.71 / 4.83 |
| s6 | 9V74 | +4.4% [+2.9, +5.4] | +0.1% [−1.0, +1.7] | −0.1% [−0.9, +1.1] | −0.2% [−1.1, +1.4] | +0.4% [−0.4, +2.0] | +1.5% [+0.9, +2.6] | 106.7 / 109.0 | 6.43 / 6.13 / 6.11 |

- The row is the CPU's: +4.4% to +5.2% against 0.39.0 on the 9V74, −0.8%
  to −2.0% on the 7763. The 9V74's var-code arms (1.074–1.105 in s3) all
  sit above its base-code arms (1.041–1.047), as in 41409560598.
- None of the five arms moves var: the pre-scan scrub (reverted with
  `23a78cd9`, or off at run time in the same binary), the band wipe, every
  collector scrub, the clamp. `rv_prescan` is the `src/` CI21b's keep run
  measured clean on a Xeon 8573C.
- The pre-scan scrub's whole cost is the Σ stacks difference, 0.3–0.4 ms
  over ~215 collections: 1.5–2 µs a collection (`VirtualQuery` walk and
  16 KiB `rep stosb`), not 170. Σ pause does not move with any arm.

## 3. Round 2: 0.40's history on the 9V74

Timed-section medians (s), unpadded / prepad16, per `src/` checkpoint (each
includes every commit before it):

| session | v0.39.0 | `f18e9c17` | `cbf1b2e8` | `e3a2de7a` | `2c600dfb` | `23427b02` | `2e91d538` | `f3ccc4dc` | `e7efe740` | **`19cf3a60`** | tip |
|---|---|---|---|---|---|---|---|---|---|---|---|
| w1 | 1.070 / 1.067 | 1.073 / 1.070 | 1.081 / 1.076 | 1.066 / 1.069 | 1.060 / 1.087 | 1.078 / 1.057 | 1.070 / 1.067 | 1.076 / 1.071 | 1.076 / 1.070 | **1.119 / 1.102** | 1.113 / 1.098 |
| w6 | 1.061 / 1.056 | 1.050 / 1.028 | 1.048 / 1.050 | 1.044 / 1.054 | 1.036 / 1.049 | 1.053 / 1.044 | 1.054 / 1.040 | 1.055 / 1.050 | 1.056 / 1.043 | **1.091** / 1.023 | 1.093 / 1.079 |
| w9 | 1.075 / 1.080 | 1.075 / 1.070 | 1.073 / 1.070 | 1.087 / 1.079 | 1.066 / 1.088 | 1.094 / 1.085 | 1.071 / 1.071 | 1.079 / 1.060 | 1.068 / 1.060 | **1.112 / 1.103** | 1.103 / 1.098 |

Every checkpoint up to `e7efe740` (the commit before) reads with 0.39.0;
`19cf3a60` reads with the tip, against v0.39.0 +4.1% [+2.7, +6.3], +3.1%
[+2.2, +4.6], +2.8% [−1.4, +6.1]. Nothing after it moves the row. One of the
six `19cf3a60` arms is fast (w6's prepad16, 1.023).

## 4. Round 3: which half of `19cf3a60`

`19cf3a60` did two things: the hit path's heap fields declared first
(`heap_hot.cr`) and `cursor_advance_word` `@[NoInline]` (it was
`@[AlwaysInline]`). Arms on the tip: `rv_hot` reverts both; `pt_inline` puts
the advance inline again and keeps the fields first (`probe/inline.patch`);
`pt_lastfields` keeps it out of line and requires `heap_hot.cr` last, so the
hot fields come after every other typed field (`probe/lastfields.patch`).
Medians unpadded / p16 / p64 (s), and `pt_inline` paired:

| session | base | var | rv_hot | pt_inline | pt_lastfields | pt_inline vs base | pt_inline vs var |
|---|---|---|---|---|---|---|---|
| w2 | 1.073 / 1.069 / 1.069 | 1.112 / 1.088 / 1.088 | 1.084 / 1.054 / 1.062 | 1.083 / 1.057 / 1.071 | 1.099 / 1.105 / 1.092 | +1.1% [−1.1, +3.1] | −1.9% [−4.5, +0.0] |
| w3 | 1.351 / 1.338 / 1.348 | 1.397 / 1.372 / 1.386 | 1.348 / 1.329 / 1.340 | 1.335 / 1.343 / 1.331 | 1.395 / 1.405 / 1.384 | −0.7% [−1.7, +0.5] | −4.5% [−5.3, −3.6] |
| w5 | 1.068 / 1.054 / 1.075 | 1.105 / 1.088 / 1.093 | 1.073 / 1.054 / 1.063 | 1.065 / 1.058 / 1.067 | 1.095 / 1.110 / 1.096 | +0.0% [−1.7, +1.3] | −4.1% [−5.4, −2.7] |

The advance inline is the whole difference: `pt_inline` reads like `rv_hot`
and like 0.39.0 at all three placements, `pt_lastfields` like the tip. Where
the hot fields sit does not matter here.

## 5. Rounds 4 and 5: the advance inline elsewhere

Binarytrees on other CPUs (round 4), medians unpadded / p16 / p64:

| session | CPU | base | var | pt_inline | pt_inline vs var | var vs base |
|---|---|---|---|---|---|---|
| w1 | EPYC 7763 | 1.297 / 1.294 / 1.316 | 1.293 / 1.277 / 1.266 | 1.337 / 1.284 / 1.285 | +3.2% [+1.1, +4.4] | −0.5% [−1.8, +1.1] |
| w2 | EPYC 7763 | 1.289 / 1.291 / 1.308 | 1.265 / 1.260 / 1.258 | 1.324 / 1.290 / 1.302 | +4.7% [+3.6, +7.0] | −1.9% [−3.1, −1.2] |
| w3 | EPYC 7763 | 1.281 / 1.273 / 1.282 | 1.257 / 1.241 / 1.247 | 1.304 / 1.266 / 1.284 | +3.5% [+1.8, +5.0] | −1.7% [−2.9, −0.6] |
| w4 | EPYC 7763 | 1.308 / 1.283 / 1.287 | 1.272 / 1.257 / 1.262 | 1.319 / 1.282 / 1.286 | +3.3% [+1.6, +4.7] | −2.2% [−4.8, −0.4] |
| w5 | EPYC 7763 | 1.285 / 1.285 / 1.304 | 1.273 / 1.256 / 1.271 | 1.314 / 1.292 / 1.272 | +3.2% [+1.7, +3.7] | −0.5% [−1.8, +0.5] |
| w6 | EPYC 9V45 | 0.885 / 0.887 / 0.873 | 0.876 / 0.861 / 0.881 | 0.883 / 0.874 / 0.873 | −0.9% [−4.0, +5.4] | +0.8% [−3.6, +4.8] |
| m1 | i7-8700B (macOS) | 1.322 / 1.331 / 1.277 | 1.335 / 1.327 / 1.281 | 1.303 / 1.288 / 1.298 | −1.5% [−3.6, +3.3] | +1.4% [−0.8, +2.9] |
| m2 | i7-8700B (macOS) | 1.696 / 1.678 / 1.609 | 1.744 / 1.733 / 1.592 | 1.654 / 1.652 / 1.656 | −4.0% [−8.7, +5.7] | +1.4% [−6.5, +7.0] |
| m3 | i7-8700B (macOS) | 1.883 / 1.986 / 1.823 | 1.858 / 1.964 / 1.775 | 1.790 / 1.835 / 1.851 | −0.9% [−10.6, +6.1] | +4.3% [−1.0, +12.1] |

- **EPYC 7763 (Windows):** out of line is the faster one. Unpadded, inline
  reads 3.2–4.7% over the tip and 0.8–3.4% over 0.39.0; its p16 and p64 arms
  sit inside or under 0.39.0's range in all five sessions. Over the three
  placements, inline averages 0.39.0's time to within 0.7% (1.302 against
  1.302 in w1) and out of line 1.8–2.7% under it.
- **EPYC 9V45 (Windows), i7-8700B (macOS):** within spread either way.

Round 5, nine benches: `pt_inline` against the tip, and the mean over the
three placements of each tree's arms (s):

| session | Binarytrees: inline vs tip | tip / inline / 0.39.0 | other rows, inline vs tip |
|---|---|---|---|
| u1, ubuntu-latest, **9V74** | +0.9% [−1.2, +3.5] | 1.262 / 1.289 / 1.288 | −1.3% to +2.0% |
| u2, ubuntu-latest, **9V74** | +2.7% [+0.0, +3.0] | 1.257 / 1.265 / 1.275 | −0.4% to +1.5% |
| a1, ubuntu-24.04-arm | +1.6% [+0.6, +2.7] | 1.033 / 1.056 / 1.068 | +0.8% to +1.0% on four JSON/Knuckeotide rows |
| ml1, macos-latest (M1) | −2.2% [−4.3, +2.6] | 0.861 / 0.862 / 0.889 | within spread |
| mi1, macos-15-intel (i7-8700B) | −0.5% [−5.7, +2.0] | 1.583 / 1.547 / 1.611 | −16.1% to +1.8%, a noisy session (Revcomp's tip arm +13.7% over 0.39.0) |
| w1, windows-latest, 9V74 | **−3.8% [−5.3, −2.5]** | 1.080 / 1.040 / 1.042 | Revcomp +9.9% unpadded (placement: inline 1.040–1.145, 0.39.0 1.037–1.144); others −0.4% to +2.1% |
| w2, windows-latest, 7763 | +4.4% [+2.3, +5.7] | 1.270 / 1.303 / 1.302 | Revcomp +12.8% unpadded (placement: 1.277–1.433 against 1.271–1.397) |

The cost is Windows': on Linux on the same 9V74, out of line reads level with
0.39.0 (+0.6%, −0.7%) and faster than inline. Out of line also stays the
faster one on arm64 Linux. Hence the fix inlines on x86-64 Windows only.

## 6. Codegen (cross-compiled here, Crystal 1.21.0, LLVM 20.1.8)

crystal-metric `--release`, `Heap#malloc<UInt64>` (`llvm-objdump`):

| tree | target | instructions | frame | stack stores |
|---|---|---|---|---|
| v0.39.0 | x86_64-windows-msvc | 516 | 0x98 | 15 |
| tip | x86_64-windows-msvc | 299 | 0x38 | 1 |
| tip, advance inline (`pt_inline`, the fix) | x86_64-windows-msvc | 530 | 0x98 | 16 |
| tip (and the fix) | x86_64-linux-gnu | 299 | 0x18 | 1 |
| tip, advance inline | x86_64-linux-gnu | 514 | 0x88 | 17 |

The fix's Windows `Heap#malloc` is instruction for instruction
`pt_inline`'s; its Linux one is the tip's. The out-of-line advance on Win64
pushes eight registers and takes a 0xa8 frame (`rsi` and `rdi` are
callee-saved there, and the caller reserves home space); on SysV it pushes
six and takes 0x58. Both run a `divq` (the chunk's block count) and the
claim's locked `or` each call. A Binarytrees run makes ~1.04 M word
advances (`cursor_word_advances` read at exit on x86-64 Linux, 2.15 GB
allocated), so the 40 ms the 9V74 loses is ~40 ns an advance: far more than
a call and eight pushes. [INFERENCE] Some Zen 4 effect specific to the Win64
sequence or to Windows on these hosts; not measured further.

## 7. The fix

`src/gcry/bitmap_alloc.cr`: `cursor_advance_word` is `@[AlwaysInline]` under
`flag?(:win32) && flag?(:x86_64)` and `@[NoInline]` elsewhere, a macro
condition around the annotation (an annotation emitted by a macro branch
applies to the `def` after it: checked in a test program's LLVM IR both
ways, and the fix's cross-compiled `Heap#malloc` matches `pt_inline`'s on
Windows and the tip's on Linux, §6). On the 9V74 the row goes level with
0.39.0 (§4, §5 w1); on the 7763 it goes from 1.8–2.7% under 0.39.0
(placement averaged) to level with it, its padded arms inside 0.39.0's
range. No other target's code changes.

## 8. The keep rule on the final source

Perf A/B dispatched on `probe/winbt-keep` at `da2082e1` (the fix's `src/`,
as pushed on `win-bt-040`), `base` = `v0.39.0`, nine benches, 15 reps,
Boehm, pads `p16 p64 bp16 bp64`, `stats=3`: one run on the five runners and
five more on windows-latest alone, to draw its CPUs. `keep.py` over each,
outputs and summaries in `keep/`:

| run | runners (Windows CPU) | rows: ok / placement / unexcused | Windows Binarytrees, var-code / base-code medians (s) |
|---|---|---|---|
| 41454341357 | all five (9V45; ubuntu-latest 9V45) | 34 / 11 / **0** | ok: 0.794 / 0.804 / 0.802 against 0.799 / 0.791 / 0.799 |
| 41454412093 | windows-latest (7763) | 3 / 6 / **0** | placement, +3.1% [+1.5, +4.4]: 1.321 / 1.278 / 1.287 against 1.286 / 1.290 / 1.288 |
| 41454424766 | windows-latest (Xeon 8370C) | 4 / 5 / **0** | ok: 1.313 / 1.320 / 1.304 against 1.319 / 1.292 / 1.302 |
| **41467319046** | windows-latest (**9V74**) | 5 / 4 / **0** | **ok**: 1.059 / 1.049 / 1.076 against 1.066 / 1.047 / 1.068 |
| 41467335301 | windows-latest (7763) | 3 / 6 / **0** | placement, +3.3% [+2.6, +5.1]: 1.328 / 1.281 / 1.295 against 1.288 / 1.271 / 1.294 |
| 41467350242 | windows-latest (7763) | 3 / 6 / **0** | placement, +1.7% [+0.9, +4.2]: 1.326 / 1.281 / 1.275 against 1.296 / 1.268 / 1.286 |

**The keep rule passes on every run.** On the 9V74 the row is clean, where
41409560598 left it unexcused. On the 7763 the unpadded arm reads 1.7–3.3%
over 0.39.0 and both padded arms sit inside 0.39.0's range, as §5 measured.
The other flagged rows are the ones earlier keep runs flagged and excused:
Windows JSON parse rows, Revcomp (+5.8% to +13.5% unpadded, its function's
alignment, `../2026-11-02-0.40-win-rows/`) and RegexDna; Intel JsonGenerate,
JsonParseSerializable, JsonParsePull, Revcomp and Binarytrees; arm64
JsonGenerate; ubuntu-latest JsonParsePure and JsonGenerate.

## 9. Checks on the final source

On the fix tree (`da2082e1`, `src/` as pushed):

- `verify.sh` (after `rm -rf lib/ameba bin/ameba`): format, lint, the three
  spec suites (307, 330, 307 examples) and the three `process_spec`
  configurations (422, 423, 423 examples, 2 pending each), 0 failures. The
  first run had one failure, regression 1 (`1_live_objects_dormant_spec.cr:91`,
  `GCRY_BITMAP_ALLOC=0` with headers); that configuration passed twice more
  on its own and in a second full `verify.sh`. The change compiles to
  nothing new on Linux: the fix's `Heap#malloc` there is the tip's
  instruction for instruction (§6).
- `make windows-typecheck`, `make darwin-typecheck`, `make
  alloc-entry-frame` (5 examples, 0 failures): pass.
- `process_spec` on Crystal 1.22.2, all three configurations: 422, 423, 423
  examples, 0 failures, 2 pending.

## Files

- `sessions/`: every probe session's `summary.md` (with its CPU) and its
  runs, trimmed (`columns` names them).
- `tab.py`: per-arm table of one session and bench.
- `probe/probe-winbt.yml`: the probe workflow as of round 5 (rounds 1–4 set
  other arms and matrices, listed above); `probe/ab-probe.patch`: its
  `ab.sh`/`ab.py` additions; `probe/knob.patch`, `inline.patch`,
  `lastfields.patch`: the patch arms.
- `keep/`: the keep-rule runs' summaries and `keep.py` output.
