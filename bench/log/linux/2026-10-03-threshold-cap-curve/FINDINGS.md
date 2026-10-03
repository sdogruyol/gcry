# The 64 MiB threshold cap: what it costs and what raising it costs

## The schedule

crystal-metric Primes, Linux x64, per collection (`GCRY_TRACE=1` for gcry,
`GC_PRINT_STATS` for Boehm):

| | heaps at which a major ran (MiB) |
|---|---|
| Boehm | 39, 52, 68, 68, 68, 68, 100, 148, 244, 372, **580** (then the program frees it) |
| gcry | 41, 52, 62, 105, 162, 217, 272, 326, 381, 436, 491, **546** |

Boehm's heap grows geometrically, ~1.5× per major, which is where its
free-space divisor of 3 sits. gcry's threshold is live × 100%, capped at
`ADAPTIVE_THRESHOLD_MAX` = 64 MiB, so past a 64 MiB live set it collects every
64 MiB, linearly: nine majors between 100 and 550 MiB against Boehm's five, each
marking the whole growing live set. Σ mark 2.8 s against Boehm's ~0.5 s, on
the same collection count overall. The cap came in with the adaptive threshold
on 2026-09-05 (`a0ec7d7`), as the upper half of an "8–64 MiB" clamp measured on
Kemal, whose live set is ~10 MB; it had not been measured on a large one.

## The curve

`docs/PERFORMANCE_PLAN_PR34.md` (Conditional B) asks for a CPU/RSS tradeoff
curve before any change to the cap, with a provisional limit of +5% peak RSS
for a throughput change. Same host, all arms interleaved in random order per
rep; cells are medians.

### Proportional cap, `max(64 MiB, live × factor / N)` (3 reps, `rows-divisor.txt`)

Wall / peak RSS against the flat cap (`div0`):

| bench | div0 (s / MiB) | N = 2 | N = 4 | N = 8 |
|---|---|---|---|---|
| Primes | 2.88 / 585 | −34% / +3% | −18% / +1% | −2% / 0% |
| JsonParsePure | 1.74 / 538 | −34% / +2% | −11% / +1% | +13% / 0% |
| RegexDna | 2.54 / 272 | +5% / **+22%** | +7% / 0% | +5% / 0% |
| Revcomp | 1.03 / 559 | +8% / **+20%** | +2% / +7% | +13% / 0% |
| JsonGenerate | 1.01 / 868 | −10% / **+11%** | −2% / **+11%** | +4% / 0% |
| JsonParseSerializable | 0.42 / 474 | +22% / **+22%** | +11% / +1% | +14% / 0% |
| JsonParsePull | 0.41 / 474 | +6% / +2% | +3% / +1% | +22% / 0% |
| Knuckeotide | 1.10 / 69 | +18% / 0% | +2% / 0% | −6% / 0% |

Three reps make wall noise of ±20% on the short benchmarks (N = 8 is the flat
cap below 512 MiB of live × factor, and still reads +13–22% on some rows); the
RSS columns and the Primes / JsonParsePure rows are the signal.

N = 2 was also run against the whole suite, 5 reps with Boehm in the same
interleave (`rows-geo-full-suite.txt`): Primes 39.0% → 65.3% of Boehm's speed,
JsonParsePure 31.2% → 49.7%; suite median 96.8% → 97.0%, median peak
0.88× → 0.91× Boehm.

### The shipped knob, `GCRY_THRESHOLD_MAX` (5 reps, `rows-knob.txt`)

Wall / peak RSS / Σ pause ms:

| bench | default | `MAX=256 MiB` | `MAX=4 GiB`, factor 50 | `MAX=4 GiB` |
|---|---|---|---|---|
| Primes | 2.73 s / 585 / 1872 | −39% / +4% / 734 | −27% / +2% / 1052 | **−52%** / +6% / 408 |
| JsonParsePure | 1.63 s / 538 / 1884 | −49% / +7% / 1049 | −34% / +2% / 1312 | **−44%** / +12% / 1093 |
| RegexDna | 2.42 s / 272 / 1 | +11% / **+80%** / 1 | +2% / **+22%** / 1 | +8% / **+80%** / 1 |
| Revcomp | 0.84 s / 559 / 2 | +11% / **+20%** / 1 | 0% / **+20%** / 2 | +11% / **+32%** / 1 |
| JsonGenerate | 0.79 s / 868 / 1521 | +11% / +11% / 901 | +17% / +11% / 803 | +2% / +11% / 760 |
| JsonParseSerializable | 0.43 s / 474 / 375 | 0% / **+24%** / 283 | +2% / **+22%** / 329 | −1% / **+24%** / 285 |
| JsonParsePull | 0.42 s / 474 / 375 | −10% / +4% / 290 | −6% / +2% / 353 | −9% / +4% / 295 |
| Knuckeotide | 0.92 s / 69 / 45 | −2% / −29% / 32 | −1% / −37% / 59 | −2% / −30% / 31 |
| Binarytrees | 0.91 s / 22 / 194 | +5% / +1% / 202 | +8% / +37% / 238 | +2% / +1% / 200 |

RegexDna and Revcomp hold large *atomic* live sets (strings): their mark is
~1 ms in total, so a bigger threshold buys them nothing and costs the full
threshold in RSS. Primes and JsonParsePure hold large *pointer* live sets
whose mark is the whole pause. A collection-cost term would tell the two
apart, but JsonGenerate and JsonParseSerializable are GC-heavy too (Σ pause
1521 and 375 ms, most of it in the untimed setup), and they pay +11–24% RSS on
every row above, so such a controller would not get under the limit either.

Knuckeotide's RSS falls by a third under every raised cap. It was not
investigated here.

## Decision

No point on the curve buys the Primes / JsonParsePure gain within the +5%
peak-RSS limit, so the default stays at 64 MiB. Changing it is a product call
on the RSS budget, which the plan asks to be made explicitly; it is open in
ROADMAP.md.

What changed is that the cap is now a knob, `GCRY_THRESHOLD_MAX`. Before, there
was no adaptive way past 64 MiB: `GCRY_THRESHOLD_FACTOR` is clamped by it,
and `GCRY_THRESHOLD` pins a fixed threshold that no longer follows the live
set. The spec (`spec/adaptive_threshold_spec.cr`) pins that a raised cap lets
live × factor through and that the default still clamps at 64 MiB.
