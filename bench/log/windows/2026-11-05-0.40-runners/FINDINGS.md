# 0.40 against 0.39.0 and Boehm on GitHub's `windows-latest` runner, second refresh (2026-11-05)

Same dispatch and method as `bench/log/linux/2026-11-05-0.40-runners/FINDINGS.md`
(run 41577045896, `var` = 0.40 at `2658369a`, `base` = `v0.39.0`, Boehm =
stock Crystal 1.21.0, 16- and 64-byte pad arms of each tree), which holds the
cross-runner summary and the keep-rule table. AMD EPYC 7763, as in the first
refresh. Memory is PeakWorkingSetSize. No Kemal (the runner has no `wrk`).
Raw: `x86-summary.md` (the numbers), `x86-runs.json`, `x86-gc-counters.txt`.
One run.

| bench | Boehm | 0.39.0 speed / peak | 0.40 speed / peak | 0.40 vs 0.39.0: timed | wall | peak |
|---|---:|---|---|---:|---:|---:|
| Primes | 1.607 s, 666 MiB | 104% / 0.94× | 104% [102, 106] / 0.93× | −0.6% [−5.6, +1.4] | +0.6% [−4.7, +1.5] | −0.1% |
| JsonParsePure | 1.918 s, 518 MiB | 103% / 1.07× | 101% [100, 101] / 1.07× | +7.5% [+6.1, +8.6] | +3.0% [+1.3, +4.0] | +0.1% |
| Binarytrees | 1.590 s, 44 MiB | 119% / 0.92× | 119% [116, 120] / 0.92× | +0.3% [−0.6, +1.2] | +0.7% [+0.0, +3.8] | −0.0% |
| JsonGenerate | 3.201 s, 1335 MiB | 101% / 0.58× | 102% [101, 102] / 0.58× | +1.3% [+0.9, +1.6] | −0.4% [−2.4, +1.3] | −0.1% |
| JsonParseSerializable | 1.939 s, 555 MiB | 104% / 0.77× | 101% [100, 102] / **0.81×** | +6.4% [+5.9, +7.9] | +3.1% [+1.8, +3.4] | +4.4% [+2.8, +5.8] |
| JsonParsePull | 1.920 s, 555 MiB | 103% / 0.77× | 101% [100, 101] / **0.81×** | +6.4% [+5.5, +7.2] | +2.8% [+1.9, +3.3] | +4.1% [+3.4, +5.6] |
| Revcomp | 3.837 s, 895 MiB | 102% / 0.57× | 96% [96, 97] / 0.57× | +15.7% [+14.6, +16.6] | +6.1% [+5.7, +6.3] | +0.0% |
| RegexDna | 4.681 s, 527 MiB | 102% / 0.43× | 101% [100, 101] / 0.43× | +0.8% [+0.5, +1.0] | +1.3% [+1.0, +1.7] | +0.0% |
| Knuckeotide | 1.524 s, 52 MiB | 95% / 1.63× | 95% [93, 97] / 1.58× [1.19, 1.64] | −0.1% [−2.7, +2.9] | −0.2% [−2.3, +3.0] | −4.0% [−6.4, +0.7] |

crystal-metric runs at 95–119% of Boehm's speed (0.39.0 in the same run:
95–119%), peak working set 0.43–0.93× on 7 of 9 rows; JsonParsePure 1.07×
(both trees) and Knuckeotide 1.58× [1.19, 1.64] (0.39.0: 1.63× [1.23,
1.68]; bimodal across reps for both) are the two above Boehm.

**Six rows are slower than 0.39.0 in wall time beyond the spread**
(JsonParsePure, JsonParseSerializable, JsonParsePull, Revcomp, RegexDna,
+1.3% to +6.1%, and Binarytrees +0.7% at the edge), one fewer than the first
refresh's seven: Primes is level (9 collections in every 0.40 run, 0.39.0 10
in 5 of 15; the growth-priced pace) and JsonGenerate's wall is level.

- **Revcomp, JsonParseSerializable, JsonParsePull, RegexDna (and
  JsonGenerate's timed section): placement by the keep rule in this run.** A
  0.40 pad arm reads inside or under 0.39.0's range on each (Revcomp
  `prepad64` 1.275 s against 1.263–1.390 s; the cross-runner file's table),
  as with all four 16-byte phases in one session
  (`../2026-11-02-0.40-win-rows/` §1–2): at the same phase the trees read
  the same, and 0.40 unpadded sits on a slow one. Revcomp follows
  `Revcomp#revcomp`'s alignment (`revcomp-addresses.txt`, from the link maps):
  0.40 puts it at ≡ 32 mod 64 (1.461 s timed), `prepad16` at ≡ 0 (1.388),
  `prepad64` at ≡ 48 (1.275); 0.39.0 at ≡ 48 (1.263), `baseprepad16` ≡ 16
  (1.264), `baseprepad64` ≡ 0 (1.390). At the same offset the trees read
  within 0.012 s.
- **JsonParsePure: placement. This run's two pads a side could not show
  it, so `../2026-11-06-win-phases/` re-ran four phases a side.** Timed
  +7.5% [+6.1, +8.6]; 0.40's arms 0.854–0.883 s, 0.39.0's 0.824–0.847 s,
  the nearest 0.7% apart. With all four 16-byte phases of both trees in
  one session, on `2658369a` (six sessions: four on EPYC 7763, one on
  9V45, one on Xeon 8573C), the ranges overlap in every session, and
  0.40 is 0.6–2.1% *faster* in wall time at the same phase. The timed
  section reads +1.5% to +2.0% pooled on the 7763, with phase 48 slow and
  phase 16 level, −2.1% on the 9V45 and −0.2% on the 8573C. The source at
  `2c600dfb` and at `e7efe740` reads level with 0.39.0, and no group of the
  later commits, reverted, lowers the band at every phase. Unpadded, 0.40
  sits at phase 32 (slow) and 0.39.0 at 48 (fast on the 7763); 0.40's fast
  phase there (16) is its 32-byte prepad, which this run does not build.
  0.40 collects 13 times to 0.39.0's 14 (the pace) with Σ mark −8.8%.
  The collection it does not run is in the setup, before crystal-metric's
  `GC.collect` ahead of the timer; the timed section runs the same
  collections in both trees.
- **Binarytrees: wall +0.7% [+0.0, +3.8], timed +0.3% [−0.6, +1.2]:
  placement.** 0.40's three arms read 1.310–1.316 s and 0.39.0's
  1.286–1.309 s. With four phases a side (`../2026-11-06-win-phases/` §4,
  three sessions on EPYC 7763), the trees' ranges meet. At the same phase
  0.40 reads +0.4% to +0.8% pooled, timed and wall, and its slow phase, 32,
  is where it sits unpadded. That is the inline word advance (`da2082e1`)
  averaging 0.39.0's time on this CPU, as `../2026-11-03-binarytrees/` §5
  and §8 measured: there, out of line read 1.8–2.7% under 0.39.0, the price
  of the EPYC 9V74's 3–5%.
- **Peaks:** JsonParseSerializable and JsonParsePull +4.4% and +4.1%
  (0.77× → 0.81× of Boehm's), the growth-priced pace's trade, with
  18.5–19.0% less Σ scanned. Knuckeotide −4.0% [−6.4, +0.7].
