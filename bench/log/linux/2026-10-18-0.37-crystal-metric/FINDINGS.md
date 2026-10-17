# crystal-metric on 0.37.0 against 0.36.0 and Boehm (Linux)

`release-0.37.0` at `4b625c87` against `v0.36.0` (`233b3ad6`) and Boehm, one
binary per arm, built as `bench/run_crystal_metric_ab.sh` builds them
(`--release`; `-Dgc_none` for gcry), Crystal 1.21.0. QEMU x86-64 guest, 12
vCPUs. `../2026-10-14-rss-budget-recheck/ab.py`: every (rep, bench) runs each
arm once in random order; whole-process wall time and `ru_maxrss`, medians.
Each session held the host-wide lock. Checksum mismatches (`err result=…`)
are the same in every arm, Boehm's included.

- `session1.md` / `session1-runs.json`: 9 reps, early evening, with other
  jobs' builds outside the lock; Brainfuck (no allocation) read 8.5%
  apart between the two gcry builds, so it bounds what that session can see.
- `session2.md` / `session2-runs.json`: 11 reps, later and quieter; the
  README table.

Session 2, speed as % of Boehm / peak RSS × Boehm:

| bench | Boehm | 0.36.0 | 0.37.0 | 0.37.0 vs 0.36.0 wall |
|---|---:|---|---|---:|
| Primes | 0.681 s, 659 MB | 103% / 0.93× | 106% / 0.94× | −2.8% |
| JsonParsePure | 0.846 s, 691 MB | 101% / 0.80× | 104% / 0.81× | −3.2% |
| Binarytrees | 0.561 s, 50 MB | 100% / 0.76× | 101% / 0.74× | −1.2% |
| JsonGenerate | 1.637 s, 1228 MB | 107% / 0.63× | 107% / 0.63× | −0.5% |
| JsonParseSerializable | 0.874 s, 572 MB | 101% / 0.73× | 105% / 0.71× | −3.7% |
| JsonParsePull | 0.889 s, 523 MB | 106% / 0.80× | 108% / 0.78× | −1.9% |
| RegexDna | 2.433 s, 513 MB | 99% / 0.53× | 98% / 0.53× | +0.7% |
| Revcomp | 2.001 s, 877 MB | 94% / 0.60× | 97% / 0.60× | −2.8% |
| Knuckeotide | 0.710 s, 40 MB | 97% / 1.67× | 100% / 1.47× | −2.7% |
| Brainfuck | 2.527 s, 14 MB | 95% / 1.00× | 98% / 1.00× | −2.6% |

Every 0.37.0-vs-0.36.0 wall difference is inside both arms' interquartile
ranges, in both sessions: 0.37.0 is level with 0.36.0 on speed on this host,
leaning faster. Brainfuck's −2.6% in session 2 is the same size as most rows'
difference, so no row's gain can be attributed to 0.37.0's mark changes from
wall time alone; their effect is measured in mark time
(`../2026-10-15-mark-cost/`, `../2026-10-16-parallel-mark-batch/`).

Peak RSS: Knuckeotide 66 → 58 MB (−12%, 1.67× → 1.47× Boehm), from the
atomic quarter in the threshold sizing (`../2026-10-17-kemal-rss/`,
`../2026-10-17-knuckeotide-rss/`); every other row within ±2.5%.
