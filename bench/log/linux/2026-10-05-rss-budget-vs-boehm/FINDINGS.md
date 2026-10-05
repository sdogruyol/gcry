# The RSS budget, measured against Boehm rather than against gcry

The open decision (ROADMAP "Decide the RSS budget for large live sets") was
framed by `../2026-10-03-threshold-cap-curve/`, which measured RSS against
gcry's own default: `GCRY_THRESHOLD_MAX=256 MiB` cost RegexDna "+80%". That
is +80% of a default that sits at 0.59× Boehm. This re-cut asks what the
same knob costs against **Boehm's** footprint, on the mark as it is after
2026-10-04 (no type layout, JsonParsePure mark −31…−37%).

Probe `probe-rss-budget` on `ccde8a7`, crystal-metric `--release`, 5 reps,
all four arms interleaved in random order per rep; whole-process wall time
(setup included) and `ru_maxrss`, medians. Cells: speed as % of Boehm / peak
RSS × Boehm.

## ubuntu-latest

| bench | gcry default | `MAX=256 MiB` | `MAX=4 GiB` | Boehm |
|---|---|---|---|---:|
| Primes | 38% / 0.89× | 50% / 0.91× | 62% / 0.93× | 1.02 s, 667 MB |
| JsonParsePure | 47% / 0.79× | 56% / 0.83× | 56% / 0.87× | 1.36 s, 695 MB |
| JsonGenerate | 53% / 0.66× | 61% / 0.73× | 63% / 0.74× | 2.35 s, 1 312 MB |
| JsonParseSerializable | 68% / 0.89× | 70% / 1.09× | 70% / 1.09× | 1.42 s, 538 MB |
| RegexDna | 91% / 0.59× | 90% / 1.06× | 90% / 1.06× | 2.78 s, 461 MB |
| Revcomp | 79% / 0.68× | 79% / 0.82× | 79% / 0.91× | 2.99 s, 816 MB |
| Binarytrees | 83% / 0.43× | 83% / 0.43× | 83% / 0.43× | 0.87 s, 50 MB |

## macos-latest

| bench | gcry default | `MAX=256 MiB` | `MAX=4 GiB` | Boehm |
|---|---|---|---|---:|
| Primes | 45% / 0.91× | 68% / 0.93× | 71% / 0.93× | 0.94 s, 696 MB |
| JsonParsePure | 50% / 1.05× | 61% / 1.11× | 61% / 1.14× | 1.12 s, 518 MB |
| JsonGenerate | 61% / 0.72× | 73% / 0.78× | 78% / 0.78× | 2.08 s, 1 198 MB |
| JsonParseSerializable | 76% / 0.86× | 81% / 1.09× | 79% / 1.09× | 1.22 s, 521 MB |
| RegexDna | 97% / 0.51× | 97% / 0.93× | 96% / 0.93× | 3.17 s, 536 MB |
| Revcomp | 105% / 0.54× | 101% / 0.72× | 97% / 0.72× | 3.19 s, 947 MB |
| Binarytrees | 87% / 0.93× | 79% / 0.93× | 87% / 0.93× | 0.77 s, 39 MB |

## What it says

- At `MAX=256 MiB` gcry's peak stays at or under 1.1× Boehm's on every row,
  on both platforms. The default undercuts Boehm by 10–60% on most of them;
  that margin is what a raised cap spends, not RSS beyond Boehm's.
- What it buys is concentrated where the mark is the cost: Primes +12 points
  (Linux) and +23 (macOS), JsonParsePure +9 and +11, JsonGenerate +8 and +12.
  The atomic-heavy rows (RegexDna, Revcomp) buy nothing and pay the most RSS,
  as in the earlier curve.
- 4 GiB adds Primes another +12 points on Linux for +0.02×; elsewhere it is
  256 MiB again or within noise.
- The rows that cross 1.0× Boehm at 256 MiB (JsonParseSerializable 1.09×,
  RegexDna 1.06×, JsonParsePure on macOS 1.11×) are the ones a "never above
  Boehm" budget would have to exclude; a "within 10% of Boehm" budget admits
  all of them.

No default is changed here; the budget is the maintainer's to set. These are
the numbers to set it against.
