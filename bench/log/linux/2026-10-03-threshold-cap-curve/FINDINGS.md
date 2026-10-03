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
whose mark is the whole pause. A duty-cycle term would not separate them
cleanly: JsonGenerate and JsonParseSerializable are GC-heavy too (Σ pause
1521 and 375 ms, most of it in the setup crystal-metric does not time), and
they pay +11–24% RSS on the rows above.

Knuckeotide's −29…−37% is not an effect: its live set never reaches 64 MiB,
so the cap does not bind, and its peak RSS is bimodal run to run under either
arm (default: 70.5, 70.6, 48.9, 70.5, 54.6, 57.3 MB; 4 GiB cap: 50.2, 54.7,
70.8, 49.6, 55.0, 70.5 MB). It stays bimodal with ASLR off (`setarch -R`:
49.4, 70.6, 70.4, 55.2, 57.0, 70.7 MB), and so is Boehm's (40.3–58.2 MB in
six runs), so the variance is the program's or the runtime's, not an
address-dependent false root in either collector.

## The rule adopted: the cap follows what the mark reads

The cap's job is to amortise the mark, and the mark's cost is the bytes it
reads, not the bytes it keeps. So the cap is now
`max(GCRY_THRESHOLD_MAX, scanned × factor / 3)`, where *scanned* is what the
last major's mark read: every object `scan_object` scanned past its atomic
early-out, plus the entries region of each `Hash` it walked (marked without
being pushed, so `scan_object` never sees it). Atomic bytes do not count. The
threshold can only rise against the old rule, and only once a major has
scanned more than 192 MiB, so small heaps (Kemal: ~10 MB live) are untouched.

First tried with the count taken in the sweep from non-atomic chunks
(`rows-sweep-scan-live.txt`, 5 reps, cap divisor 2 and 3): divisor 2 put +11%
on JsonGenerate's peak, divisor 3 kept every benchmark within +1–2% and took
Primes −19%, JsonParsePure −14% (timed). Two defects in that count moved it
into the mark: a large object's atomicity is on its block header, not its
chunk, so large strings counted as scannable (RegexDna +22% peak until it was
fixed); and the freelist allocator mixes kinds in one chunk, so under
`-Dgcry_block_headers` a chunk-level count cannot tell them apart at all.

Shipped (mark-based, divisor 3), 5 reps interleaved with Boehm
(`rows-mark-scanned-final.txt`); "whole" is the process's wall time, setup
included:

| bench | before: timed / whole / peak | after vs before: timed / whole / peak | after, whole × Boehm | after, peak × Boehm |
|---|---|---|---:|---:|
| Primes | 2.50 s / 2.54 s / 585 MiB | −17% / −17% / +1% | 2.14 | 0.90 |
| JsonParsePure | 1.54 s / 2.83 s / 538 MiB | +1% / +1% / 0% | 2.30 | 0.79 |
| RegexDna | 2.26 s / 3.12 s / 272 MiB | 0% / 0% / 0% | 1.00 | 0.60 |
| Revcomp | 0.79 s / 2.69 s / 559 MiB | −7% / −1% / 0% | 1.02 | 0.64 |
| JsonGenerate | 0.78 s / 3.47 s / 868 MiB | +2% / −7% / 0% | 1.51 | 0.70 |
| JsonParseSerializable | 0.40 s / 1.51 s / 474 MiB | −1% / −3% / 0% | 1.19 | 0.82 |
| JsonParsePull | 0.38 s / 1.46 s / 474 MiB | −3% / −1% / 0% | 1.20 | 0.91 |
| Knuckeotide | 0.84 s / 0.93 s / 53 MiB | +5% / +5% / +29% (bimodal, above) | 1.02 | 1.75 |
| Binarytrees | 0.84 s / 0.84 s / 22 MiB | +3% / +3% / 0% | 1.11 | 0.43 |
| Matmul | 0.47 s / 0.48 s / 36 MiB | +1% / 0% / 0% | 1.03 | 1.21 |
| Brainfuck | 3.40 s / 3.40 s / 13 MiB | −2% / −2% / 0% | 0.99 | 1.00 |
| Threadring | 0.56 s / 0.56 s / 13 MiB | −1% / −1% / 0% | 0.94 | 1.00 |
| Brainfuck2 | 1.50 s / 1.51 s / 13 MiB | +2% / +2% / 0% | 0.99 | 1.00 |

Peak RSS is unchanged on every benchmark the rule can reach. JsonParsePure
gains nothing at divisor 3: its mark reads 240 of its 357 MiB live set, so the
cap ends at 80 MiB. At the end of their runs the cap reads 114 MiB on
JsonGenerate (343 MiB scanned) and 64 MiB on JsonParseSerializable.

## Still open

Primes is still 2.1× Boehm's process time and JsonParsePure 2.3×. More of the
gap is available only by spending RSS — divisor 2, or the raised floor in the
knob table — and the plan asks for that budget to be decided explicitly. It
is in ROADMAP.md. The other half is the per-collection mark cost
(`../2026-10-03-mark-prefilter/`).

`GCRY_THRESHOLD_MAX` stays as the floor of the cap: before it there was no
adaptive way past 64 MiB at all, since `GCRY_THRESHOLD_FACTOR` was clamped by
it and `GCRY_THRESHOLD` pins a threshold that no longer follows the live set.
