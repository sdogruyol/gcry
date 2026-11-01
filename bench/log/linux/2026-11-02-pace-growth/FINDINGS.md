# The pace prices a growing heap's next cycle (2026-11-02)

The ROADMAP item "The pace prices the next cycle at the last one's cost"
(`../../macos/2026-11-01-primes-collections/`). The pace (`Heap.threshold_pace_pct`,
`src/gcry/collect.cr`) is the threshold that would have held the cycle just
measured to 10% of the mutator time before it. A heap that grows every
stretch reads more in its next cycle than in this one, so Primes spent
18–36% of each stretch collecting. Where its seventh major landed, and
whether a tenth collection fitted, followed a few percent of mark time.
The plain growth-priced pace (`pace-growth.patch`) removed the step but put
Knuckeotide's peak up 17–28% on Linux and JsonParsePure at 1.10× Boehm's.
Branch `pace-growth-040` from `release-0.40.0` (`07b61d28`).

## Verdict

**Landed: the pace prices the next cycle's growth only when the last two
stretches both grew, and against at least the cap's 64 MiB floor of
scanned bytes** (measured as `e7bed2b4`, tag
`archive/pace-growth-040-e7bed2b4`; on the branch rebased onto `87ccf4f4`
with the same diff; `Heap.pace_survived`, `PACE_GROWTH_SCAN_FLOOR`). In
the five-runner A/B against the tip (41293132278), Primes took a tenth
collection in 1 of 75 runs (M1), against the tip's 13 of 75 (7 of 15 on
Intel, 4 of 15 on Windows, 2 of 15 on M1). JsonParsePure took 6.7–13.3%
fewer collections, and its peak stays 1.07× Boehm's on arm64 and Windows.
Knuckeotide's peak is within −2.6% to +3.6% of the tip's, and Kemal does
not change. The cost is peak memory on JsonParseSerializable and
JsonParsePull: +3% to +16% against the tip, at most 0.99× Boehm's (arm64
JsonParsePull, where 9 of 15 runs took 14 collections instead of 16).
Against v0.39.0 every flagged row is placement in a same-session pad band
except Intel Binarytrees. That row is the tip's own, and the pads do not
excuse it for either tree (§5).

## 1. The variants

One probe build (`6e85a9e1`, tag `archive/probe-pace-growth-knob`;
`variants.patch`) selects the formula by environment. Every arm is traced
and interleaved per rep, 12 reps, on all five runners: 41288184899 (Linux,
Windows) and 41289711115 (macOS). The workflow (it carries the last run's
arms; the variants' were `GCRY_PACE_VARIANT=1–3` and `GCRY_PACE_FLOOR` on
`6e85a9e1`) and scripts are in `probe/`. `probe_pace.sh` builds one binary
per SHA, and `probe_pace.py` runs the arms and records `ru_maxrss`, so
there is no peak on Windows. `probe/export.py` wrote `schedules.ndjson`,
one run per line, from all four probe runs.

- `tip`: no growth term, which is the tip's formula.
- `g1`: `pace-growth.patch`, T = P / (1 − P × survived / (allocated × scanned)).
- `g2`: g1 with the growth weighted by the mark's share of the cycle
  (`mark_ns / cycle_ns`): the next cycle adds mark time, not sweep or flush.
- `g3`: g1 with `survived` at most the previous stretch's survival rate ×
  this stretch's allocation: a step is priced only once it repeats.
- `g1f16`, `g1f64`: g1 with `scanned` floored at 16 or 64 MiB.
- `g3f64`: g3 and the 64 MiB floor. This is the candidate.

Primes runs at 10 collections:

| runner | tip | g1 | g2 | g3 | g1f16 | g1f64 | g3f64 |
|---|---:|---:|---:|---:|---:|---:|---:|
| ubuntu-latest | 5/12 | 0/12 | 0/12 | 0/12 | 0/12 | 0/12 | 0/12 |
| ubuntu-24.04-arm | 0/12 | 0/12 | 0/12 | 0/12 | 0/12 | 0/12 | 0/12 |
| macos-latest | 2/12 | 0/12 | 0/12 | 0/12 | 0/12 | 0/12 | 0/12 |
| macos-15-intel | 8/12 | 0/12 | 0/12 | 0/12 | 0/12 | 0/12 | 0/12 |
| windows-latest | 1/12 | 0/12 | 0/12 | 0/12 | 0/12 | 0/12 | 0/12 |

Peak against `tip` (median of per-rep ratios):

| row | runner | g1 | g2 | g3 | g1f16 | g1f64 | g3f64 |
|---|---|---:|---:|---:|---:|---:|---:|
| Knuckeotide | ubuntu-latest | +23.2% | +23.1% | +13.0% | +20.2% | +5.8% | +6.9% |
| Knuckeotide | ubuntu-24.04-arm | +26.4% | +26.1% | +8.9% | +18.6% | +6.9% | +1.5% |
| Knuckeotide | macos-latest | +3.4% | +3.1% | +2.1% | +3.1% | +2.8% | +2.9% |
| Knuckeotide | macos-15-intel | +1.3% | +0.6% | +1.3% | +1.3% | +1.3% | +1.3% |
| JsonParsePure | ubuntu-latest | +2.7% | +2.5% | −0.4% | +2.8% | +2.7% | −0.2% |
| JsonParsePure | ubuntu-24.04-arm | +2.7% | +2.7% | +0.0% | +2.6% | +2.7% | +0.1% |
| JsonParsePure | macos-latest | +2.5% | +2.6% | +2.6% | +2.6% | +0.5% | +0.5% |
| JsonParsePure | macos-15-intel | +1.3% | +0.9% | −1.9% | +1.3% | +1.3% | −1.8% |
| JsonParseSerializable | ubuntu-latest | +0.3% | +1.1% | +2.0% | +5.5% | +6.8% | +6.5% |
| JsonParseSerializable | ubuntu-24.04-arm | +5.6% | +4.4% | +2.1% | +1.7% | +12.7% | +7.8% |
| JsonParsePull | ubuntu-latest | +1.0% | +1.5% | +2.6% | +4.9% | +7.1% | +7.8% |
| JsonParsePull | ubuntu-24.04-arm | +5.5% | +4.8% | +2.1% | +2.2% | +12.8% | +8.6% |

JsonParsePure's time against `tip`: g1 −2.2% to −5.9%, g3 −4.6% to +0.9%,
g3f64 −2.5% to +0.1%. JsonGenerate and Binarytrees move within ±1% on Linux
and Windows (`probe/variants_table.py` over the two runs' artifacts gives
every table).

### Why Knuckeotide's peak moved

Knuckeotide's scanned set is 0.07–0.16 MiB for 50 majors. It steps to 0.82
and then 6.07 MiB in two stretches, holds, and in most runs dips once (to
0.1–3.1 MiB, a major landing during a rebuild) before it returns to 6.07. At the
step the cycle is 0.8 ms, 0.6–0.7 ms of it mark, after 6.7 ms of mutator
time. That cycle alone holds a 12% cost, a pace of about 175%. Its growth
(5.25 of 6.07 MiB, 34% of the stretch's allocation) gives P × survived /
(allocated × scanned) ≈ 1.1 in g1, so the pace goes to the maximum. The
stretch after it allocates 32 MiB where the tip allocates 19 MiB, and the
same happens again when the set returns from a dip. Pace and next threshold
at the step, medians of 12 runs:

| runner | tip | g1 | g2 | g3 | g1f16 | g1f64 | g3f64 |
|---|---:|---:|---:|---:|---:|---:|---:|
| ubuntu-latest | 176%, 19.0 MiB | 300%, 32.4 | 300%, 32.4 | 244%, 26.3 | 296%, 32.0 | 208%, 22.4 | 186%, 20.1 |
| ubuntu-24.04-arm | 169%, 16.5 MiB | 300%, 29.3 | 300%, 29.3 | 213%, 20.8 | 262%, 25.6 | 184%, 18.0 | 174%, 17.0 |

- The mark's share (g2) changes nothing. A growing heap's cycle is almost
  all mark: 85–90% at Knuckeotide's step, and 95–98% at Primes' majors 5–7.
- The trend (g3) stops the price of the return from a dip, whose previous
  stretch shrank. It still prices the step at the rate of the stretch
  before it (0.66 of 8.3 MiB, 8%).
- The floor prices the step at 6/64 of g1. A floor of 16 MiB is too low.
  Primes' decisive cycles scan 42 MiB or more, so a 64 MiB floor leaves
  their price nearly whole, and they reach the maximum anyway.
- g3f64 leaves the step at the tip's pace. Its remaining peak differences
  are where the dips fall, which moves the tip's own peak by as much (tip
  54–67 MiB over 12 runs on `ubuntu-latest`).

On the JSON rows the scanned set grows 33–37% of each stretch's allocation,
stretch after stretch, so the trend prices them as g1 does. The floor
lowers the price of their first majors, under 64 MiB. That moves where the
last major falls before the document is complete, and so the peak (§3).

## 2. The candidate, traced

`e7bed2b4` is g3f64 written as `Heap.pace_survived` (the trend) and
`PACE_GROWTH_SCAN_FLOOR` (`ADAPTIVE_THRESHOLD_MAX`). Probe 41293194136,
Primes and Knuckeotide, 20 reps, `base` = v0.39.0 (`c0d570c5`), `tip` =
`07b61d28`, `cand` = `e7bed2b4`:

| runner | Primes at 10: base / tip / cand | 5th pace (median): base / tip / cand | Knuckeotide peak, cand vs tip |
|---|---|---|---:|
| ubuntu-latest | 0 / 0 / 0 of 20 | 300 / 282 / 300 | +3.4% |
| ubuntu-24.04-arm | 0 / 0 / 0 | 300 / 300 / 300 | +1.4% |
| macos-latest | 1 / 4 / 0 | 300 / 300 / 300 | +0.7% |
| macos-15-intel | 3 / 9 / 0 | 262 / 248 / 300 | +0.0% |
| windows-latest | 16 / 18 / 1 | 249 / 246 / 300 | — |

Primes' fifth pace is at the maximum in every candidate run, against a
cycle at 18–36% of its stretch. The one Windows run at 10 priced no growth
at the fourth major. That is the first stretch that grows, and the trend
needs two, so its pace was 239% from cost alone against 279% in the other
runs. The seventh major then landed at 296.6 MiB, under the step. Windows
Primes: cand 1.585 s, tip 1.701 s (−7.1%).

## 3. Against the tip, five runners

Perf A/B 41293132278: `var` = `e7bed2b4`, `base` = `07b61d28`, nine
benches, 15 reps, `stats=3`, Kemal 15 trials (`ab/41293132278-*`). Time
(timed section) / wall / peak, var against base, medians of per-rep ratios:

| bench | ubuntu-latest | ubuntu-24.04-arm | macos-latest | macos-15-intel | windows-latest |
|---|---:|---:|---:|---:|---:|
| Primes | +0.1% / +0.1% / −0.4% | −0.3% / −0.2% / −0.0% | +2.0% / +2.3% / −0.0% | −2.5% / −2.8% / −0.4% | −4.0% / −3.8% / −0.1% |
| JsonParsePure | −1.0% / −0.5% / +0.2% | −0.9% / −1.5% / +0.0% | −2.1% / −3.1% / +0.5% | −0.7% / +0.1% / −1.0% | −1.8% / −3.4% / −0.1% |
| Binarytrees | +3.0% / +3.2% / −0.1% | +0.1% / +0.1% / +0.0% | +1.6% / +1.6% / +0.0% | +2.0% / +2.0% / −0.0% | −0.7% / −2.0% / +0.0% |
| JsonGenerate | +4.0% / +0.7% / +0.0% | −0.6% / −0.6% / +0.1% | −1.1% / −0.6% / −0.1% | −0.9% / −1.7% / −0.0% | −6.1% / −2.6% / −0.1% |
| JsonParseSerializable | −0.5% / +0.4% / +6.1% | −0.8% / −1.1% / +7.3% | −0.8% / −1.6% / −0.5% | +0.9% / +2.9% / +4.8% | +0.6% / −1.8% / +4.3% |
| JsonParsePull | +0.0% / +0.4% / +7.5% | −0.9% / −1.6% / +15.8% | −0.8% / −1.3% / −0.7% | −0.2% / +0.7% / +2.8% | +1.4% / −2.1% / +3.2% |
| Revcomp | +2.5% / +1.1% / −0.0% | +0.4% / +0.7% / +0.0% | −0.5% / +0.2% / +0.0% | −0.8% / −1.8% / −0.0% | −8.3% / −2.9% / +0.0% |
| RegexDna | +0.1% / −0.1% / −0.0% | −0.1% / +0.3% / +0.0% | −0.1% / −0.2% / −0.0% | −2.5% / −1.7% / +0.0% | +0.1% / +0.1% / −0.0% |
| Knuckeotide | −0.7% / −0.5% / −2.6% | +0.6% / +0.5% / +0.4% | +1.2% / +1.1% / +0.4% | −2.5% / −2.3% / +0.0% | +2.1% / +0.9% / +3.6% |

Collections, tip → candidate, medians of 15 runs:

| bench | ubuntu-latest | ubuntu-24.04-arm | macos-latest | macos-15-intel | windows-latest |
|---|---:|---:|---:|---:|---:|
| Primes | 9 → 9 | 9 → 9 | 9 → 9 | 9 → 9 | 9 → 9 |
| JsonParsePure | 15 → 13 | 15 → 14 | 16 → 14 | 14 → 13 | 14 → 13 |
| Binarytrees | 208 → 199 | 230 → 229 | 226 → 218 | 202 → 200 | 213 → 209 |
| JsonGenerate | 14 → 13 | 14 → 13 | 13 → 13 | 14 → 13 | 14 → 13 |
| JsonParseSerializable | 14 → 13 | 17 → 15 | 18 → 17 | 15 → 14 | 15 → 14 |
| JsonParsePull | 13 → 11 | 16 → 14 | 16 → 15 | 14 → 13 | 14 → 13 |
| Revcomp | 28 → 28 | 28 → 28 | 28 → 28 | 26 → 26 | 28 → 28 |
| RegexDna | 25 → 25 | 25 → 25 | 24 → 24 | 22 → 22 | 24 → 24 |
| Knuckeotide | 68 → 68 | 72 → 72 | 70 → 70 | 67 → 67 | 66 → 66 |

Primes at 10: tip 0, 0, 2, 7 and 4 of 15 in that order; candidate 0, 0,
1, 0, 0. Revcomp and RegexDna keep the tip's schedule exactly (same
collections, same Σ scanned), so their ±2.5% is this session's placement.
`ubuntu-latest` JsonGenerate's +4.0% timed section is +0.7% wall, and
Binarytrees' +3.0% [−4.0, +10.5] is within its spread.

The peak cost is on JsonParseSerializable and JsonParsePull. Their
schedules are bimodal: on arm64, 9 of 15 JsonParsePull runs took 14
collections and peaked at 490 MiB, and the other 6 took 15 and peaked at
438–449 MiB. The tip took 16 in every run, at 418–425 MiB. In the keep-rule
session (§4) the same row took 15 at 419–441 MiB. Fewer majors in a growing
document leave a longer last stretch before it completes. [INFERENCE]
Where that stretch ends against the document's last allocation decides the
peak, which is why it moves in steps between sessions.

Kemal (`ab/41293132278-*-kemal-summary.md`): `/json` and `/` within each
other's IQR on all four runners, with the same 0.710–0.711 collections per
1 000 requests and the same peak.

## 4. The keep rule against v0.39.0

Perf A/B 41293138039: `base` = `v0.39.0`, nine benches, 15 reps, pads
`p16 bp16`, Boehm (`ab/41293138039-keep.txt`, `keep.py` from
`../2026-11-01-0.40-keep-rule/`). Rows slower than base beyond their spread
with no pad overlap: `ubuntu-latest` JsonParseSerializable (+5.3%) and
JsonParsePull (+8.0%); Windows JsonParsePure, JsonParseSerializable,
JsonParsePull, Revcomp and RegexDna; Intel Binarytrees (+5.1%). Revcomp and
RegexDna run the tip's schedule unchanged (§3). With one pad a side the
bands are two points wide.

Perf A/B 41297103900 re-ran the three runners with four pads (`p16 p64 bp16
bp64`) and 21 reps (`ab/41297103900-keep.txt`):

| runner | bench | time, var vs base | var | p16 | p64 | base | bp16 | bp64 | |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| ubuntu-latest | JsonParsePure | +3.1% [+2.3, +5.3] | **0.621** | **0.623** | **0.631** | 0.604 | 0.634 | 0.630 | pads |
| ubuntu-latest | JsonGenerate | +3.7% [+2.8, +4.4] | **0.978** | **1.004** | **0.943** | 0.943 | 0.978 | 1.006 | pads |
| windows-latest | JsonParsePure | +2.7% [+2.0, +3.7] | **0.915** | 0.924 | **0.903** | 0.889 | 0.905 | 0.920 | pads |
| windows-latest | JsonParseSerializable | +5.1% [+4.3, +5.5] | 0.725 | 0.728 | **0.693** | 0.692 | 0.687 | 0.724 | pads |
| windows-latest | JsonParsePull | +4.9% [+3.9, +5.6] | **0.705** | 0.712 | **0.679** | 0.671 | 0.671 | 0.708 | pads |
| windows-latest | Revcomp | +7.3% [+6.9, +7.8] | **1.374** | **1.409** | **1.278** | 1.280 | 1.247 | 1.458 | pads |
| windows-latest | RegexDna | +0.7% [+0.4, +1.0] | 3.877 | **3.856** | **3.820** | 3.840 | 3.836 | 3.872 | pads |
| macos-15-intel | Binarytrees | +4.9% [+2.8, +8.8] | 1.563 | 1.517 | 1.582 | 1.437 | 1.477 | 1.437 | not excused |

Bold: var-code medians inside or under the base-code range. `ubuntu-latest`
JsonParseSerializable and JsonParsePull are not flagged in this session.

## 5. Intel Binarytrees

Intel Binarytrees is slower than v0.39.0 beyond its spread in four of the
candidate's five sessions, and the tip's in two of four. Binarytrees only,
21 reps, `p16 p64 bp16 bp64`, `base` = v0.39.0, unless noted:

| run | tree | time, var vs base | var-code medians | base-code medians | |
|---|---|---:|---|---|---|
| 41293138039 (nine benches, 15 reps, `p16 bp16`) | candidate | +5.1% [+2.3, +6.2] | 1.331, 1.377 | 1.293, 1.302 | not excused |
| 41297103900 (nine benches) | candidate | +4.9% [+2.8, +8.8] | 1.563, 1.517, 1.582 | 1.437, 1.477, 1.437 | not excused |
| 41304526811 | candidate | +4.6% [−1.5, +7.7] | 1.511, **1.429**, 1.508 | 1.446, 1.445, 1.404 | within spread |
| 41306354258 | candidate | +6.0% [+1.8, +7.4] | 2.028, 2.033, 2.049 | 1.934, 2.001, 1.903 | not excused |
| 41306362719 | candidate | +4.1% [+0.2, +6.2] | 1.442, 1.456, 1.459 | 1.406, 1.396, 1.373 | not excused |
| 41306370503 | tip (`c91a84ea`) | +5.7% [+4.1, +7.0] | 1.746, 1.739, 1.713 | 1.657, 1.685, 1.668 | not excused |
| 41306378233 | tip (`c91a84ea`) | +3.6% [−2.6, +6.3] | 1.378, 1.427, 1.367 | 1.323, 1.358, 1.295 | within spread |
| 41304533544 (`base` = tip `07b61d28`) | candidate vs tip | −4.1% [−6.8, +13.3] | 2.287, 2.295, 2.312 | 2.264, 2.270, 2.155 | within spread |

The 0.40 keep rule read the tip at +5.2% (41233405753, not excused) and
+2.8% (41244421059, excused by `p64`). Against the tip the candidate reads
+2.0% [−1.7, +4.6] (41293132278) and −4.1%, and it changes Binarytrees'
collections by −2.7% to +0.5%: its live set is under 5 MiB, so the floor
prices its growth at a few percent of the 64 MiB. Both trees take 192–208
collections in these sessions to 0.39.0's 182–201. [INFERENCE] The row's
difference from 0.39.0 is the tip's, and it has not been attributed.

## 6. Small heaps and the floor

The floor is the cap's own (`ADAPTIVE_THRESHOLD_MAX`, 64 MiB), and the cap
stays at it until the scan reaches three times that. A heap scanning
S < 64 MiB has its growth priced at S / 64 MiB of the full price: 1/16 for
a 4 MiB live set. Primes' decisive cycles scan 42 MiB and more, and
they price the maximum anyway (§1). A steady live set has no growth to
price: `survived` is 0, or the trend's previous stretch shrank. Kemal
`/json` and `/` take 0.710–0.711 collections per 1 000 requests with both
the candidate and the tip, on all four runners Kemal runs on (§3).
Binarytrees, under 5 MiB live, changes its collections by −2.7% to +0.5%.

## 7. Peak against Boehm

Every row's median peak is within 1.1× Boehm's except Knuckeotide's, which
is exempt (`ab/peak-x-boehm.txt`). The highest other rows, candidate
(tip or 0.39.0) across the three sessions:

| row | runner | 41293132278 (vs tip) | 41293138039 (vs 0.39.0) | 41297103900 |
|---|---|---:|---:|---:|
| JsonParsePure | ubuntu-24.04-arm | 1.07× (1.07×) | 1.07× (1.07×) | — |
| JsonParsePure | windows-latest | 1.07× (1.07×) | 1.07× (1.07×) | 1.07× (1.07×) |
| JsonParsePull | ubuntu-24.04-arm | 0.99× (0.85×) | 0.86× (0.85×) | — |
| JsonParseSerializable | ubuntu-24.04-arm | 0.90× (0.84×) | 0.85× (0.84×) | — |
| Binarytrees | macos-15-intel | 0.96× (0.96×) | 0.96× (0.96×) | 0.96× (0.96×) |

## 8. On the rebased tree

The branch was rebased onto `87ccf4f4`, whose `collect.cr` gained the
large-cache settle in the flush that the pace counts as cycle time. Probe
41308020706 traced the tip `87ccf4f4` against the candidate rebased onto it
(`ee825d74`), 15 reps, on all five runners:

| runner | Primes at 10: tip / cand | Knuckeotide peak, cand vs tip | JsonParsePure collections: tip → cand | JsonParsePure time vs tip |
|---|---|---:|---|---:|
| ubuntu-latest | 12 / 0 of 15 | −0.6% | 15 → 13–14 | +2.9% |
| ubuntu-24.04-arm | 0 / 0 | +1.0% | 15 → 14 | +0.3% |
| macos-latest | 10 / 1 | +0.0% | 16 → 14–15 | −0.5% |
| macos-15-intel | 4 / 1 | −0.0% | 14 → 13–14 | −1.2% |
| windows-latest | 5 / 1 | — | 14 → 13 | +5.3% |

Of the candidate's three runs at 10, two priced no growth at the fourth
major (the first growing stretch, M1 156% and Windows 234% from cost
alone), and Intel's seventh major read 186% after landing at 320.6 MiB. The
traced JsonParsePure times are one session each. The untraced A/B against
the tip (§3) read −1.8% on Windows and −1.0% on `ubuntu-latest`.
