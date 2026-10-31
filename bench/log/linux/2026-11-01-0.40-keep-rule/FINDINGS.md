# 0.40.0's tree against 0.39.0 on the five runners (keep rule), 2026-11-01

`release-0.40.0` against `v0.39.0` (`c0d570c5`), `perf-ab.yml`, Crystal 1.21.0.
The keep rule: no crystal-metric row slower than base beyond its spread
(paired timed section or wall, interquartile range above zero) on any of the
five runners. A flagged row is excused as code placement only when, in the
same session, a var-code arm (`var`, `prepad16`, `prepad64`) reads a median
inside or below the range of the base-code arms (`base`, `baseprepad16`,
`baseprepad64`). `keep.py` applies it to a downloaded run
(`python3 keep.py <dir holding perf-ab-*/>`); `raw/` holds the summaries.

Default-path source changes since 0.39.0: `cbf1b2e8` (mark word loop unrolled
by four), `6aa84284` + `e3a2de7a` (free's mark clear and the claim; acquire
fence and atomic `occ` load), `f18e9c17` (large-cache counters atomic),
`b209b395` (staging counter atomic), `435b3511` (idle baseline), `b4a707f4`
(long reservation front, Linux and macOS), the Darwin high-heap commits
(`28780034`, `e6149bcb`, `16d7112d`). Two compile to nothing on 1.21.0:
`bf607374` gates both reopens on `compare_versions(Crystal::VERSION, "1.22.1") < 0`,
which 1.21.0 meets as 0.39.0 did unconditionally, and `2c600dfb`'s
`GC.syscall(&)` has no caller in 1.21.0's stdlib (`grep -rn GC.syscall` over
1.21.0's `src/`: none; 1.22.x calls it from `pthread.cr` and the condition
variables), so the method is never instantiated.

**Verdict: every flagged row is placement.** No change lands; nothing in the
tree is reverted.

## 1. The combined run, 41233405753

var `9dc77af5` (the tree before `b209b395` and `2c600dfb`), 15 reps, nine
benches, pads `p16 bp16`. Rows slower beyond their spread, timed-section
medians in seconds:

| runner | bench | time, var vs base | var | prepad16 | base | baseprepad16 | |
|---|---|---:|---:|---:|---:|---:|---|
| ubuntu-latest | Binarytrees | +2.4% [+0.1, +3.5] | 1.206 | 1.195 | 1.182 | 1.188 | not excused |
| ubuntu-latest | JsonParsePure | +1.0% [+0.2, +1.5] | 0.812 | 0.788 | 0.806 | 0.805 | pads |
| ubuntu-latest | JsonGenerate | +0.9% [+0.7, +1.1] | 1.272 | 1.259 | 1.260 | 1.331 | pads |
| ubuntu-latest | JsonParseSerializable | +1.4% [+1.1, +1.6] | 0.671 | 0.643 | 0.662 | 0.653 | pads |
| ubuntu-latest | JsonParsePull | +1.1% [+0.6, +1.7] | 0.646 | 0.620 | 0.637 | 0.625 | pads |
| ubuntu-24.04-arm | JsonGenerate | +2.1% [+1.6, +2.4] | 1.096 | 1.104 | 1.075 | 1.074 | not excused |
| ubuntu-24.04-arm | JsonParseSerializable | +0.6% [+0.4, +0.9] | 0.650 | 0.646 | 0.646 | 0.648 | pads |
| ubuntu-24.04-arm | JsonParsePull | +0.8% [+0.6, +1.0] | 0.639 | 0.635 | 0.634 | 0.633 | not excused |
| windows-latest | JsonGenerate | +1.1% [+0.2, +3.7] | 0.755 | 0.741 | 0.738 | 0.739 | not excused |
| windows-latest | JsonParsePull | +3.3% [+2.1, +5.0] | 0.386 | 0.381 | 0.371 | 0.382 | pads |
| windows-latest | Revcomp | +8.0% [+7.3, +10.6] (wall +1.5%) | 0.777 | 0.744 | 0.722 | 0.704 | not excused |
| macos-15-intel | Primes | +3.5% [+0.7, +10.5] | 1.829 | 1.785 | 1.661 | 1.777 | not excused |
| macos-15-intel | Binarytrees | +5.2% [+3.3, +8.6] | 1.354 | 1.326 | 1.286 | 1.322 | not excused |

`macos-latest`: no row slower beyond its spread. With one pad a side the
bands are two points wide; the seven rows marked "not excused" are what this
file settles.

## 2. Same-session pad bands, 21 reps

The tip `2c600dfb` against `v0.39.0`, four pad arms (`p16 p64 bp16 bp64`), on
the four runners with flagged rows: 41244414917 (`ubuntu-latest`),
41244416901 (arm64), 41244418947 (Windows), 41244421059 (Intel).

| runner | bench | time, var vs base | var | p16 | p64 | base | bp16 | bp64 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| ubuntu-latest | Binarytrees | +8.1% [+5.4, +9.1] | 0.995 | 0.952 | **0.913** | 0.925 | 0.947 | 0.953 |
| ubuntu-24.04-arm | JsonGenerate | +0.6% [+0.2, +1.1] | 1.083 | **1.086** | **1.080** | 1.075 | 1.068 | 1.088 |
| ubuntu-24.04-arm | JsonParsePull | +0.6% [+0.5, +1.3] | 0.639 | **0.633** | **0.632** | 0.634 | 0.634 | 0.631 |
| windows-latest | Revcomp | +19.5% [+18.7, +19.9] (wall +7.5%) | 1.497 | **1.381** | **1.302** | 1.256 | 1.256 | 1.383 |
| windows-latest | JsonGenerate | +2.3% [+2.0, +3.2] | 1.371 | **1.277** | **1.345** | 1.335 | 1.287 | 1.278 |
| macos-15-intel | Primes | +5.6% [−1.7, +12.2], within spread | 1.844 | 1.819 | 1.924 | 1.835 | 1.858 | 1.683 |
| macos-15-intel | Binarytrees | +2.8% [+1.0, +5.5] | 1.342 | 1.357 | **1.312** | 1.299 | 1.350 | 1.278 |

Bold: var-code medians inside (or under) the base-code range. Every flagged
row has one; the other rows in these runs (`ubuntu-latest` Revcomp, RegexDna,
JsonGenerate; arm64 Binarytrees) are within spread. Padding alone moves
`ubuntu-latest` Binarytrees by 9% of var's time (0.913–0.995) and 0.39.0's by
3% (0.925–0.953); Windows Revcomp by 15% and 10%.

### Windows Revcomp is where `Revcomp#revcomp` lands

The link maps (`syms/`) put `Revcomp#revcomp(String)` at a different offset
in each arm. In both 21-rep sessions on this runner type (41244418947 and
41248448693, which read the same arm times to 0.01 s) the time follows the
function's address mod 64, whichever tree the code is from:

| arm | tree | `revcomp` at | mod 64 | timed section, s |
|---|---|---|---:|---:|
| base | 0.39.0 | `0x1400f76f0` | 48 | 1.256 / 1.256 |
| baseprepad16 | 0.39.0 | `0x1400f7710` | 16 | 1.256 / 1.259 |
| prepad64 | 0.40 | `0x1400f95b0` | 48 | 1.302 / 1.294 |
| baseprepad64 | 0.39.0 | `0x1400f7740` | 0 | 1.383 / 1.386 |
| prepad16 | 0.40 | `0x1400f9580` | 0 | 1.381 / 1.379 |
| var | 0.40 | `0x1400f9560` | 32 | 1.497 / 1.497 |

0.39.0 at offset 0 reads what 0.40 reads at offset 0. Unpadded, 0.40 puts
`revcomp` 0x1e70 bytes further on than 0.39.0 does, at offset 32, the
slowest of the four. Revcomp's collector work is 28 collections and 0.6 ms
of marking per run.

## 3. Attribution probes

Each default-path change reverted on the tip, measured as the tip (`var`)
against the probe (`base`), so `var` vs `base` is the change's cost. 15 reps,
Primes, Binarytrees, JsonGenerate, JsonParsePull, Revcomp, pads `p16 bp16`,
no Boehm arm.

| run | reverted | probe (base) |
|---|---|---|
| 41244467452 | `cbf1b2e8` (mark unroll) | `e9e9f0a9` |
| 41244473161 | `e3a2de7a` `6aa84284` (free/claim) | `a77c15ab` |
| 41244478965 | `b209b395` `f18e9c17` (counters) | `751ec5fa` |
| 41244498623 | `435b3511` (idle) | `6f91e0cc` |
| 41244504354 | `b4a707f4` (reservation; no Windows) | `7df8c197` |

The flagged rows, time of the tip against the probe, then `prepad16` /
`baseprepad16`:

| row | unroll | free/claim | counters | idle | reservation |
|---|---|---|---|---|---|
| ubuntu-latest Binarytrees | −1.1% [−2.1, +0.5] | −5.5% [−13.7, +3.6] | +1.0% [−0.5, +1.4] | −0.2% [−1.8, +1.6] | −0.3% [−3.2, +0.7] |
| arm64 JsonGenerate | +0.4% [+0.1, +1.2]; 1.087/1.084 | −0.1% [−0.5, +1.1] | −0.4% [−0.8, +0.0] | −0.1% [−0.5, +0.5] | +0.2% [−1.2, +0.9] |
| arm64 JsonParsePull | +0.5% [+0.2, +0.7]; 0.634/0.643 | +1.4% [+1.3, +1.7]; 0.632/0.635 | +0.0% [−0.2, +0.2] | +1.3% [+1.2, +1.7]; 0.637/0.635 | +0.8% [+0.5, +1.2]; 0.633/0.642 |
| Windows Revcomp | −0.2% [−2.7, +0.3] | +4.3% [+3.8, +5.1]; 1.156/1.253 | +3.2% [+2.3, +5.1]; 1.177/1.242 | +5.1% [+3.7, +5.4]; 1.387/1.389 | — |
| Windows JsonGenerate | −0.2% [−1.0, +0.1] | +2.9% [+2.1, +3.6]; 1.001/1.025 | +1.3% [−0.4, +2.1] | +7.0% [+6.4, +8.1]; 1.286/1.349 | — |
| Intel Primes | −5.9% [−8.4, −0.4] | +0.2% [−0.6, +1.3] | −3.3% [−6.9, +5.5] | −1.3% [−7.8, +3.5] | +3.6% [−8.0, +13.6] |
| Intel Binarytrees | +0.4% [−1.0, +1.5] | +0.7% [−3.0, +1.6] | +4.4% [−4.7, +8.8] | +3.1% [−3.9, +11.0] | +1.1% [−0.7, +4.5] |

No change carries a flagged row by itself. Where a revert reads the tip
slower beyond spread, the padded tip reads level with or faster than the
padded probe (arm64 JsonParsePull in four probes, Windows Revcomp in three,
Windows JsonGenerate in two): one tree's layout against another's, as in §2.
Four of the five probes move the tip's unpadded arm64 JsonParsePull by +0.5
to +1.4%, whichever change they remove.

## 4. arm64 JsonGenerate's fifteenth collection

The one row with a schedule difference. JsonGenerate's collection count sits
on a step of the pace (`update_threshold_pace`: the threshold that holds a
cycle's cost to 10% of the mutator time between cycles). On arm64, 0.39.0
collects 14 times and the tip 14 or 15:

| run | base | var | prepad16 | prepad64 | baseprepad16 | baseprepad64 |
|---|---|---|---|---|---|---|
| 41233405753 | 15×14 | 13×15, 2×14 | 15×15 | — | 15×14 | — |
| 41244416901 | 21×14 | 15×15, 6×14 | 18×15, 3×14 | 17×15, 4×14 | 21×14 | 20×14, 1×15 |
| 41248448693 | 15×14 | 12×15, 3×14 | 13×15, 2×14 | 14×15, 1×14 | 15×14 | 11×14, 4×15 |

A run with 15 takes longer: 1.100 s against 1.075 s in 41233405753 (that
run's +2.1%), 1.083 against 1.077 in 41244416901, 1.088 against 1.077 in
41248448693. The unroll probe is the one that removes it: there the tip
without `cbf1b2e8` collected 14 times in 30 of 30 runs (padded or not) and
the tip 15 in 11 of 30; with any other change reverted the probe still
reached 15 (freeing 12 of 30, counters 16 of 30, idle 30 of 30, reservation 6
of 30). [INFERENCE] A cheaper cycle lowers the pace, and the threshold with
it, by enough to fit a fifteenth major. 0.39.0 crosses the same step when
padded (`baseprepad64` 4 of 15 on arm64 in 41248448693; on `ubuntu-latest`,
14 → 15 collections in 12 of 15 `baseprepad64` runs in the same session), and
the row's time is inside 0.39.0's pad band in both 21-rep and 15-rep
sessions, so it passes the rule. The unroll's own gains in its probe:
`ubuntu-latest` JsonGenerate −5.7% [−6.1, −5.1], JsonParsePull −1.6%, Intel
Primes −5.9%.

## 5. Σ mark on x86 Linux Revcomp and RegexDna

The combined run's +15.1% and +10.6% are 0.52 → 0.60 ms and 0.49 → 0.54 ms
over 28 and 25 collections, about 2–3 µs a collection, on 2 MB scanned in a
1.3–2.5 s timed section. They hold under padding (combined run: `prepad16`
0.59, `baseprepad16` 0.52), so they are code, and the unroll probe has them:
the tip 0.558 / 0.473 ms (`prepad16`) against 0.435 / 0.437 without
`cbf1b2e8`. No wall time moves with them.

## 6. The keep rule on the tip, five runners: 41248448693

`2c600dfb` against `v0.39.0`, all five runners, nine benches, 15 reps,
Boehm, pads `p16 p64 bp16 bp64`. Rows slower beyond their spread, var-code
medians against base-code medians (s):

| runner | bench | time, var vs base | var / p16 / p64 | base / bp16 / bp64 |
|---|---|---:|---|---|
| ubuntu-latest | Primes | +3.8% [+1.9, +6.0] | 1.500 / 1.516 / 1.505 | 1.466 / 1.452 / 1.557 |
| ubuntu-latest | JsonParsePure | +3.0% [+2.8, +3.9] | 0.882 / 0.842 / 0.870 | 0.853 / 0.858 / 0.863 |
| ubuntu-latest | Binarytrees | +4.4% [+2.9, +6.2] | 1.227 / 1.182 / 1.206 | 1.176 / 1.205 / 1.181 |
| ubuntu-latest | JsonParseSerializable | +4.0% [+3.4, +4.7] | 0.754 / 0.711 / 0.746 | 0.724 / 0.722 / 0.747 |
| ubuntu-latest | JsonParsePull | +5.0% [+4.5, +5.3] | 0.740 / 0.703 / 0.756 | 0.704 / 0.710 / 0.726 |
| ubuntu-24.04-arm | JsonGenerate | +1.3% [+1.0, +2.1] | 1.089 / 1.092 / 1.085 | 1.076 / 1.074 / 1.089 |
| ubuntu-24.04-arm | JsonParsePull | +0.5% [+0.3, +0.9] | 0.639 / 0.635 / 0.633 | 0.635 / 0.636 / 0.632 |
| ubuntu-24.04-arm | RegexDna | +0.1% [+0.0, +0.2] | 2.289 / 2.285 / 2.286 | 2.286 / 2.283 / 2.283 |
| windows-latest | JsonParsePure | +3.7% [+1.7, +4.5] | 0.841 / 0.841 / 0.809 | 0.809 / 0.825 / 0.841 |
| windows-latest | JsonGenerate | +3.1% [+2.8, +3.7] | 1.382 / 1.272 / 1.340 | 1.339 / 1.283 / 1.280 |
| windows-latest | JsonParseSerializable | +5.7% [+5.3, +7.3] | 0.723 / 0.724 / 0.683 | 0.682 / 0.695 / 0.727 |
| windows-latest | JsonParsePull | +6.3% [+5.2, +7.6] | 0.718 / 0.711 / 0.676 | 0.671 / 0.682 / 0.715 |
| windows-latest | Revcomp | +18.7% [+18.2, +20.1] (wall +7.4%) | 1.497 / 1.379 / 1.294 | 1.256 / 1.259 / 1.386 |
| windows-latest | RegexDna | +1.0% [+0.9, +1.3] | 3.463 / 3.465 / 3.442 | 3.430 / 3.449 / 3.501 |

Each has a var-code median inside the base-code range: placement by the
rule. `macos-latest` and `macos-15-intel`: no row slower beyond its spread
(Intel Primes +3.5% [−1.5, +6.8], Binarytrees +4.1% [−0.9, +7.4]). The
combined run's arm64 JsonGenerate, JsonParsePull, Windows Revcomp,
JsonGenerate and `ubuntu-latest` Binarytrees reappear here, each inside the
band again.

Peak: the only rise beyond spread above 1% is Intel JsonParsePull, +5.1%
[+2.1, +7.9] (413 → 434 MiB, Boehm 512 MiB), with 0.39.0 padded by 16 at 467
MiB in the same session; the combined run read the same row +4.1% and
JsonParseSerializable +5.0%, with `baseprepad16` at 441 and 455 MiB. Every
row stays under 1.1× Boehm (JsonParsePure 1.07× on arm64 and Windows, both
arms) except Knuckeotide, the documented exception
(`../2026-10-21-knuckeotide-pin/`): 1.03–1.67× for 0.40's arms, 1.04–1.68×
for 0.39.0's.

## Verdict

Every row the combined run left unexcused is inside 0.39.0's pad band once
the band has two pads a side (§2, 21 reps), and again on the tip on all five
runners (§6). Windows Revcomp, the largest, follows `Revcomp#revcomp`'s
alignment, and 0.39.0 at the tip's alignment reads the tip's time (§2). No
reverted change makes a flagged row slower by itself (§3). arm64
JsonGenerate's extra collection is a schedule step the unroll brings closer
(§4); its time is inside the band and 0.39.0 reaches the step when padded.
