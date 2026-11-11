# Primes' tenth collection and arm64 JsonGenerate's fifteenth on 0.40 (2026-11-01)

In Perf A/B 41253485376 (0.40 against v0.39.0, 15 reps), Primes collected 10
times instead of 9 in 11 of 15 runs on `macos-15-intel` and on
`windows-latest` (0.39.0: 4 and 6 of 15), +7.6% and +6.3% wall. arm64 Linux
JsonGenerate goes from 14 to 15 collections
(`../../linux/2026-11-01-0.40-keep-rule/FINDINGS.md` §4). Branch `primes-040`
from `origin/release-0.40.0` (`1452b941`).

## Verdict

- **No 0.40 commit adds Primes' tenth collection on Intel or Windows.** The
  ninth-or-tenth step is a property of the pacing that 0.39.0 has too. In
  the same session, 20 traced reps each, 0.39.0 reaches 10 as often as the
  tip: Intel 25 of 60 against 28 of 60 over three sessions, Windows 14 of 20
  against 15 of 20. 0.39.0 with 16 bytes of padding reaches it in 17 and 19
  of 20. No revert moves the tip consistently. The unroll's revert reads
  15/20 and 19/20 against the tip's 10/20 and 15/20, and the other reverts
  3–9 of 20 against the tip's 8 and 10 in their sessions. The split in
  41253485376 is that session's draw: its own `baseprepad16` arm (0.39.0
  padded) took 10 in 11 of 15 on Intel.
- On Intel, two things change under the same count. The Darwin high heap
  (`28780034`) closes one path to 10 that 0.39.0 takes in a quarter of its
  runs (§3). The tip's decisive cycle is 4–6% cheaper, which opens the
  other path more often (§4). Together they leave the rate unchanged.
- **arm64 JsonGenerate's fifteenth collection is the mark unroll
  (`cbf1b2e8`)**: 0 of 20 runs without it, 6 of 20 with it, and 0 of 60 for
  0.39.0 in the same session. A cheaper cycle lowers the pace. The project
  already recorded that response when the 2026-10-23 batch scan took
  JsonGenerate from 13 to 14 collections (ROADMAP, per-object mark cost).
- The extra Primes major is not a reset or counter fix doing its job, and it
  is not new in 0.40. Nothing lands. The pacing has a weakness here: it
  prices the next cycle at the cost of the one just measured, and Primes'
  live set doubles every cycle. A pace that prices the growth removes the
  step on every runner (§6), but it reschedules every growing row and costs
  peak memory (Knuckeotide +17% to +28%), so it is an open ROADMAP item
  rather than a 0.40 fix.

## 1. What decides a major

`maybe_collect` collects when `bytes_since_gc` reaches `gc_threshold`.
After each major, `adapt_after_sweep` sets the threshold as follows:
`min(live × factor, cap) × pace`. The cap is the larger of 64 MiB and a
third of the scanned bytes. The pace (`update_threshold_pace`,
100–300%) is the threshold that would hold this cycle's cost (stop to end
of the post-STW flush) to 10% of the mutator time before it. That threshold
is `allocated × cycle_ns / (mutator_ns × 0.1)`, taken over the unpaced one.
So the schedule follows measured time. No large-cache counter enters the
formula, but the recycling trim that `keep = large_since` decides runs
inside the measured cycle. §3's path goes through that trim.

Primes' timed run allocates about 601 MiB of trie that all survives. Traced
runs (`GCRY_TRACE`, `collect_end`: threshold, pace, scanned) on every
runner follow one shape: majors 4–7 at about 10, 42, 140 and 300 MiB
scanned. After them the threshold is 38 MiB, then the live-sized base
(about 45 MiB) × pace, then 192 MiB (3 × the 64 MiB cap), then the live set
(3 × a third of it). The step follows from that:

- If the seventh major comes at or above about 300.5 MiB scanned (half the
  run's allocation), the run ends before the next threshold. That gives 9
  collections: 7 automatic majors, plus two releasing ones once the trie is
  dead (pace 100, 0.1 MiB scanned).
- If it comes below that, an eighth automatic major marks the whole
  ~545 MiB live set (121–188 ms of mark, median by session) and the run has
  10 collections.

The boundary is sharp. Of the 466 traced Primes runs on Intel and Windows
that do not take §3's path, every 9 had its seventh major at ≥ 300.68 MiB,
and every 10 but one (303.7 MiB, a `bp64` run) at ≤ 300.33 MiB.

Where the seventh major lands is set by the pace of the earlier cycles,
mostly the fifth. A fifth pace of ≤ 245% gave 10 in 161 runs and 9 in 2. A
pace of 246–252% gave 60 and 38, and a pace above 252% gave 23 and 182. The
fifth pace comes from an 11–34 ms mark of 42 MiB against a 39–112 ms
mutator stretch, so a few percent either way in that ratio decides the run.
Code placement alone moves it by that much (`p16`/`p64`/`bp16`/`bp64` in
§2). The realized cost is far above the pace's 10% target: 18–36% of the
mutator time in each stretch before majors 4–7, and before the eighth
automatic one, in 9-collection and 10-collection runs alike.

## 2. Runner data

Probe runs (push-triggered on `probe/primes-040-pace`, since deleted;
scripts in `probe/`, whose workflow carries the last run's arm list; the
earlier runs' arms are in the table). Each arm is crystal-metric built
against the gcry source at a SHA, optionally prepadded (`p16` = 16 bytes of
nops ahead of all code, as perf-ab's `prepad16`). The arms are interleaved in random
order per rep, 20 reps, every run traced. Per-run schedules are in
`schedules.ndjson`, one run per line. `collections` is a list with one
entry per major: [scanned MiB, the next threshold MiB, pace %, cycle ms
from `collect_start` to `collect_end`, mutator ms since the previous
`collect_end`, mark ms, flush ms].

Primes runs at 10 collections, of 20:

| run | runner | 0.39.0 | `bp16` | `bp64` | tip | `p16` | `p64` | other arms (tip with one change reverted, or the candidate) |
|---|---|---:|---:|---:|---:|---:|---:|---|
| 41263993332 | windows-latest | 14 | 19 | 17 | 15 | 19 | 20 | −unroll 19; candidate 0 |
| 41265482244 | macos-15-intel | 10 | 17 | 9 | 10 | 12 | 12 | −unroll 15; candidate 0 |
| 41267310974 | macos-15-intel | 9 | — | — | 8 | — | — | −counters (`751ec5fa`) 5; −idle (`6f91e0cc`) 3 |
| 41267945003 | macos-15-intel | 6 | — | — | 10 | — | — | −reservation (`7df8c197`) 9; −freeing (`a77c15ab`) 9; `GCRY_HIGH_HEAP=0` 11 |
| 41263993332 | ubuntu-24.04-arm | 0 | 0 | 0 | 0 | 0 | 0 | −unroll 0; candidate 0 |

The keep-rule sessions give the same picture (`runs.json` of each run, 15
reps). Primes runs at 10 with 0.39.0 against 0.40, unpadded / padded:

| run | Intel 0.39.0 | Intel 0.40 | Windows 0.39.0 | Windows 0.40 |
|---|---|---|---|---|
| 41233405753 | 3/15, 13/15 | 10/15, 9/15 | 3/15, 0/15 | 2/15, 0/15 |
| 41248448693 | 6/15, 19/30 | 9/15, 17/30 | 3/15, 6/30 | 5/15, 16/30 |
| 41253485376 | 4/15, 11/15 | 11/15, 10/15 | 6/15, 0/15 | 11/15, 11/15 |

In the revert probes (tip against the tip with one change reverted, Primes
at 10), 41244467452 (unroll) reads in both directions: Intel 2/15 against
8/15, Windows 12/15 against 4/15. Freeing reads 2/2 and 13/11, counters
8/8 and 15/15, idle 2/5 and 13/15, reservation 7/8. `ubuntu-latest`, which
reads 9 in 41253485376, took 10 in 9 of 15 for the tip and 12 of 15 for
0.39.0 padded by 64 in 41248448693. It is the same step there.

The dev host (x86 Linux, 12 CPUs, shared, interleaved under the heavy lock)
gives 0.39.0 11/20, tip 11/20 and tip without the unroll 7/20.

## 3. Intel: the high heap closes 0.39.0's other path

In 17 of 60 runs of 0.39.0 on Intel (8 of 20 padded by 16, 1 of 20 by 64),
the fourth major's pace is 100 instead of about 300. The next thresholds are
then 22, 42–71 and 96–143 MiB, and all 34 such runs (across every arm)
collect 10 times. In those runs the fourth major's flush is 0.05–0.1 ms.
In all but 2 of the other Intel runs it is 3.2–6.8 ms: the recycling trim
of Primes' dead 40 MB sieve (`collect.cr`, `keep = large_since`), which the
pace counts as cycle time. Without the trim the cycle reads as cheap and
the pace stays at 100.

The tip never takes this path (0 of 220 tip-tree runs on Intel), except
with `GCRY_HIGH_HEAP=0` (8 of 20). Reverting the counters, idle,
reservation or freeing changes does not bring it back, so the high heap is
what closes it. [INFERENCE] On the low heap, a stale word sometimes still
points into the dead sieve at the fourth major, so the trim waits. Keeping
33-bit integers from reading as heap pointers is the high heap's purpose.
Windows has no such path: no run there had a fourth pace of 100.

## 4. The other path: the fifth cycle's pace

Excluding §3's path, in the two quiet Intel sessions:

| session | arm | 5th mark (ms) | 5th mutator (ms) | 5th pace (median) | at 10 |
|---|---|---:|---:|---:|---:|
| 41267310974 | 0.39.0 | 17.0 | 58.1 | 263 | 2/13 |
| 41267310974 | tip | 16.3 | 57.6 | 250 | 8/20 |
| 41267310974 | −counters | 17.0 | 59.1 | 254 | 5/20 |
| 41267310974 | −idle | 16.6 | 58.4 | 256 | 3/20 |
| 41267945003 | 0.39.0 | 16.7 | 54.9 | 265 | 1/15 |
| 41267945003 | tip | 15.6 | 56.0 | 248 | 10/20 |
| 41267945003 | −reservation | 15.8 | 56.4 | 249 | 9/20 |
| 41267945003 | −freeing | 15.9 | 56.1 | 253 | 9/20 |
| 41267945003 | `GCRY_HIGH_HEAP=0` | 16.3 | 56.1 | 254 | 3/12 |

Pooled, 0.39.0 reaches 10 by this path in 3 of 28 such runs and the tip in
18 of 40. Including 41265482244, the totals are 8 of 43 against 28 of 60.
On Windows (41263993332) the fifth mark is 13.8 ms for 0.39.0, 13.3 for
the tip and 13.9 without the unroll, with paces of 249, 246 and 252.

[INFERENCE] The tip's 4–6% cheaper fifth mark on Intel is the most likely
cause of the difference. The decisive quantity is mark time, so the unroll
is the natural suspect. Its own A/B, though, read Σ mark level on Intel and
−1% to −5% on Windows (ROADMAP, per-object mark cost), and no single revert
separates it from placement. In the noisier Intel session (41265482244) the
revert's fifth mark was cheaper than the tip's (19.8 against 24.6 ms), and
the four padded arms of 0.39.0 and the tip span 20–24 ms.

## 5. arm64 JsonGenerate

JsonGenerate's pace is not at the maximum while its document grows
(170–250% over majors 2–9), so its schedule follows the cycle cost all the
way. In the tip's 15-collection runs, majors 7 and 8 read 218–222% and
278–281% where 0.39.0 reads 237–243% and 300%. The tenth major comes at
265 MiB instead of 290 MiB, and an eleventh fits at 340 MiB, just before
the final 343 MiB. Σ mark is 324 ms for the tip against 337 ms for the
revert and 341 ms for 0.39.0 (medians over all 20 reps). The time is
1.087 s against 1.082 and 1.075, inside 0.39.0's pad band (1.075–1.089).
This is the documented response: cheaper marking spent on a smaller
threshold.

## 6. Candidate: price the next cycle's growth

`pace-growth.patch` (not applied) changes what the pace predicts. The next
cycle marks this cycle's scanned bytes S, plus the part of the next stretch
that survives. In the last stretch `survived` = ΔS of `allocated`. Holding
the next cycle to the target gives `T = P / (1 − P × survived /
(allocated × S))`, where P is the current paced threshold, or the maximum
when the denominator is ≤ 0. A steady live set is unchanged.

Traced (41263993332, 41265482244): Primes takes 9 in 20 of 20 on Intel,
Windows and arm64, with the fifth pace at 300. Perf A/B 41265551528 (the
candidate as `var` against the tip, all five runners, nine benches, 15
reps, pads `p16 bp16`):

- Primes: 9 in all 150 runs (`var` and `prepad16`). Windows −6.2% wall
  against a tip that drew 10 in all 15. Elsewhere the tip mostly drew 9 and
  the row is level.
- JsonParsePure, JsonGenerate, JsonParseSerializable, JsonParsePull: 5.6–20%
  fewer collections, wall +0.2% to −4.4%, peak −3.8% to +5.8%.
  JsonParsePure's peak is +1.6% to +2.8%, which takes it from 1.07× to
  1.10× Boehm on arm64 and Windows, the budget's edge.
- Knuckeotide: peak +16.9% on x86 Linux (1.27× → 1.60× Boehm), +28.4% on
  arm64 (1.13× → 1.46×) and +4.3% on Windows, on the row already over
  budget, and wall +1.7% and +3.9%. Its scanned set is ~80 KiB for most
  of the run and jumps to 3–6 MiB when its hash table is rebuilt (dev host
  trace). That growth prices the pace at the maximum.
- Binarytrees arm64: +3.6% wall.

The candidate is not clearly better. It trades the step for peak memory on
every growing row, and its Knuckeotide cost is a schedule regression. It
would need the growth weighted by the mark's share of the cycle, or a
floor on S, and a budget run of its own. Recorded as an open ROADMAP item.
