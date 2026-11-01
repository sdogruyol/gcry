# 0.40 against 0.39.0 and Boehm on GitHub's `windows-latest` runner (2026-11-01)

Same dispatch and method as `bench/log/linux/2026-11-01-0.40-runners/FINDINGS.md`
(run 41253485376, `var` = 0.40 at `69bfcaf2`, `base` = `v0.39.0`, Boehm =
stock Crystal 1.21.0, 16-byte pad arms), which holds the cross-runner
summary. Memory is PeakWorkingSetSize. No Kemal (the runner has no `wrk`).
Raw: `x86-summary.md` (the numbers), `x86-runs.json`, `x86-gc-counters.txt`.
One run.

| bench | Boehm | 0.39.0 speed / peak | 0.40 speed / peak | 0.40 vs 0.39.0: timed | wall | peak |
|---|---:|---|---|---:|---:|---:|
| Primes | 1.626 s, 666 MiB | 104% / 0.93× | 98% [94, 103] / 0.93× | +3.6% [+1.3, +8.9] | +6.3% [+1.6, +9.0] | −0.0% |
| JsonParsePure | 1.948 s, 518 MiB | 104% / 1.07× | 101% [99, 102] / 1.07× | +4.0% [+2.7, +6.0] | +2.0% [+0.3, +3.1] | +0.1% |
| Binarytrees | 1.602 s, 44 MiB | 119% / 0.92× | 120% [118, 121] / 0.92× | −0.5% [−1.1, +1.5] | −0.9% [−1.5, +1.3] | −0.0% |
| JsonGenerate | 3.218 s, 1335 MiB | 102% / 0.58× | 100% [98, 101] / 0.58× | +2.6% [+1.9, +3.5] | +2.5% [+1.0, +4.1] | −0.0% |
| JsonParseSerializable | 1.947 s, 555 MiB | 104% / 0.77× | 101% [99, 102] / 0.77× | +5.5% [+4.5, +6.7] | +2.9% [+2.2, +3.9] | −0.1% |
| JsonParsePull | 1.933 s, 556 MiB | 103% / 0.77× | 100% [99, 102] / 0.76× | +5.0% [+4.4, +6.6] | +2.5% [+2.0, +3.1] | −1.1% |
| Revcomp | 3.835 s, 897 MiB | 102% / 0.57× | 95% [94, 96] / 0.57× | +18.8% [+18.1, +19.8] | +7.3% [+7.1, +7.7] | −0.0% |
| RegexDna | 4.640 s, 527 MiB | 101% / 0.43× | 99% [99, 100] / 0.43× | +0.7% [+0.6, +1.1] | +1.4% [+1.1, +1.8] | +0.0% |
| Knuckeotide | 1.548 s, 52 MiB | 96% / 1.57× | 98% [97, 99] / 1.19× | −2.3% [−3.1, +0.0] | −1.7% [−4.1, +0.0] | −2.3% [−16.1, +1.7] |

crystal-metric runs at 95–120% of Boehm's speed (0.39.0 in the same run:
96–119%), peak working set 0.43–0.93× on 7 of 9 rows; JsonParsePure 1.07×
(both trees) and Knuckeotide 1.19× [1.18, 1.66] (0.39.0: 1.57× [1.21,
1.70]; paired within the spread, its peak is bimodal across reps for both)
are the two above Boehm.

**Seven rows are slower than 0.39.0 in wall time beyond the spread**
(Primes, JsonParsePure, JsonGenerate, JsonParseSerializable, JsonParsePull,
Revcomp, RegexDna, +1.4% to +7.3%). With one pad a side, only JsonGenerate
has a 0.40 arm at or under 0.39.0's (`prepad16` 1.292 s against 1.306–1.345 s in
the timed section; `../../linux/2026-11-01-0.40-runners/keep.txt`). What the
other six are:

- **Revcomp**, timed +18.8%, wall +7.3%: `Revcomp#revcomp`'s alignment. In
  both 21-rep sessions of the keep-rule file (§2) its time followed the
  function's address mod 64 whichever tree the code was from, and 0.40
  unpadded lands at the slowest offset, inside a ~15% pad band. 0.40 padded
  by 16 bytes reads +9.8% here (1.388 against 1.264 s). The link maps put
  `revcomp` where they did there (`var` ≡ 32 mod 64, `prepad16` ≡ 0, `base`
  ≡ 48, `baseprepad16` ≡ 16), and the arms read within 0.015 s of the times
  there (1.506, 1.388, 1.264, 1.270 s here).
- **JsonParsePure, JsonParseSerializable, JsonParsePull, RegexDna** were
  flagged the same way in the keep-rule file's tip run with two pads a side
  (41248448693, §6: +3.7%, +5.7%, +6.3%, +1.0% timed), and each had a 0.40
  arm inside 0.39.0's band there. This run's one pad a side does not show
  it; placement, shown since in same-session runs with all four 16-byte
  phases of both trees (`../2026-11-02-0.40-win-rows/` §1–2): the trees
  read the same at the same phase, and 0.40 unpadded sits on a slow one,
  0.39.0 on a fast one.
- **Primes**, +6.3% wall, was within the spread in both earlier 0.40 runs
  (41233405753, 41248448693). It sits on a 9-or-10-collection step (a run with 10 is 3–4%
  slower): 0.40 collected 10 times in 11 of 15 runs, 0.39.0 in 6, 0.39.0
  padded in none; at equal counts 0.40 is still 2–3% slower here, as the JSON
  rows are. With four phases a side the trees read the same at equal counts
  and the same phase, and 0.39.0 reaches the tenth collection in 0 to 20 of
  21 runs depending on its placement (`../2026-11-02-0.40-win-rows/` §3).

Knuckeotide is −1.7% wall and −2.3% timed, faster at the edge of its spread.
