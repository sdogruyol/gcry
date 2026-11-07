# 0.40 against 0.39.0 and Boehm on GitHub's macOS runners (2026-11-01)

Same dispatch and method as `bench/log/linux/2026-11-01-0.40-runners/FINDINGS.md`
(run 41253485376, `var` = 0.40 at `69bfcaf2`, `base` = `v0.39.0`, Boehm =
stock Crystal 1.21.0, 16-byte pad arms), which holds the cross-runner
summary. Memory is `ru_maxrss`. Raw: `arm64-*` (`macos-latest`, Apple M1, 3
vCPUs), `intel-*` (`macos-15-intel`, i7-8700B); `*-summary.md` are the
numbers. One run each.

What 0.40 changes on Darwin beyond the other platforms: every heap mapping is
asked for at a random base 16–32 TiB up (`GCRY_HIGH_HEAP`,
`../2026-10-31-heap-high/`), so no 33-bit integer in a system library's data
reads as a pointer into the heap. JsonGenerate's peak falls on both Macs.

## macOS arm64 `macos-latest`

| bench | Boehm | 0.39.0 speed / peak | 0.40 speed / peak | 0.40 vs 0.39.0 wall | peak |
|---|---:|---|---|---:|---:|
| Primes | 0.964 s, 696 MiB | 109% / 0.89× | 109% [107, 112] / 0.89× | −0.8% [−1.9, +3.6] | +0.0% |
| JsonParsePure | 1.150 s, 518 MiB | 99% / 0.93× | 100% [98, 102] / 0.92× | −1.3% [−2.9, +1.6] | −1.2% |
| Binarytrees | 0.719 s, 39 MiB | 93% / 0.94× | 93% [88, 94] / 0.94× | −0.7% [−3.1, +2.4] | −0.0% |
| JsonGenerate | 2.179 s, 1198 MiB | 102% / 0.74× | 104% [103, 105] / **0.64×** | −1.2% [−6.3, +1.7] | −13.6% [−13.7, −13.5] |
| JsonParseSerializable | 1.255 s, 498 MiB | 103% / 0.89× | 105% [101, 106] / 0.87× | −0.0% [−3.0, +2.7] | −1.7% |
| JsonParsePull | 1.225 s, 521 MiB | 102% / 0.85× | 102% [98, 105] / 0.84× | −0.5% [−2.9, +4.3] | −0.8% |
| Revcomp | 2.993 s, 834 MiB | 98% / 0.61× | 99% [95, 100] / 0.61× | +0.8% [−0.9, +3.7] | −3.5% |
| RegexDna | 3.207 s, 536 MiB | 98% / 0.43× | 98% [96, 99] / 0.43× | +0.6% [−0.8, +4.1] | −0.0% |
| Knuckeotide | 1.007 s, 47 MiB | 91% / 1.32× | 91% [90, 99] / 1.32× | −0.0% [−2.8, +2.3] | −2.8% |

No wall time is slower than 0.39.0 beyond its spread. RegexDna's timed
section is +1.0% [+0.2, +4.4], with 0.40's arms (2.360, 2.375 s) inside
0.39.0's (2.336–2.439 s): placement by the keep rule. Σ mark is lower on
Binarytrees (−21.2% [−24.6, +0.9]), Knuckeotide (−16.0%), RegexDna (−11.0%)
and JsonParsePure (−6.7%) at the same collection counts ([INFERENCE] the mark
loop unrolled by four, `cbf1b2e8`, which lowers it on arm64 Linux too).
Binarytrees reads 93% of Boehm for both trees here against 100% for 0.39.0
in 0.39's run; Boehm's own time is 0.719 s here against 0.901 s there.

Kemal, 15 trials (`arm64-kemal-summary.md`; paired `var`/`base` per trial
computed from `arm64-kemal-runs.json`):

- `/json`: 105.2% [96.9, 110.6] of Boehm at 1.38× (20.6 against 14.8 MiB);
  0.39.0 100.2%, 1.40×; paired +3.9% [−8.8, +9.3], peak −0.9%.
- `/`: 104.0% [92.2, 114.7] at 1.33×; 0.39.0 102.1%, 1.35×; paired +1.9%
  [−5.2, +7.7], peak −1.3%. The `/` trials are bimodal again for every arm
  (Boehm 63–134k req/s), as in 0.39's run; level here.
- Work per 1 000 requests: the same CPU and collections (0.710–0.711 on
  `/json`, 0.153 on `/`) for both trees, and 26–30% less pause (`/json` 0.268
  against 0.361 ms, `/` 0.058 against 0.083 ms). On Intel the pause is
  11–13% less (0.724 against 0.833 ms, 0.152 against 0.171 ms); on both
  Linux runners it is level. Not attributed.

## macOS x86_64 `macos-15-intel`

crystal-metric, speed % of Boehm / peak × Boehm, 0.40 (0.39.0): Primes 95%
(101%) / 0.92× (0.93×), JsonParsePure 102% (102%) / 0.81× (0.82×),
Binarytrees 140% (143%) / 0.96×, JsonGenerate 94% (100%) / 0.65× (0.75×),
JsonParseSerializable 102% (103%) / 0.79× (0.75×), JsonParsePull 106% (102%)
/ 0.84× (0.82×), Revcomp 98% (101%) / 0.53× (0.63×), RegexDna 101% (102%) /
0.38× (0.39×), Knuckeotide 99% (101%) / 1.56×. This run's spread is wide
(Primes' IQR 89–100% of Boehm, Boehm's Primes 2.289 s against 1.76–1.77 s in
the keep-rule runs).

- **Primes +7.6% wall [+3.9, +14.7]**, not inside 0.39.0's band with one pad
  a side. It is the 9-or-10-collection step (cross-runner file): 0.40 at 10
  in 11 of 15 runs, 0.39.0 in 4 and padded in 11; at equal counts level
  (9: 2.095 against 2.155 s, 10: 2.541 against 2.493 s). The keep-rule
  file's runs read +3.5% [+0.7, +10.5] and +3.5% [−1.5, +6.8].
- JsonGenerate +5.2% wall [+0.4, +12.4], with 0.40 padded (2.318 s) inside
  0.39.0's arms (2.373–2.564 s): placement.
- Peaks: JsonGenerate −13.6% [−13.7, −0.0] and Revcomp −11.7% [−22.8, −6.2]
  (the high heap, as `../2026-10-31-heap-high/` §5 measured on this runner);
  JsonParseSerializable +9.0% [+1.1, +15.2] (473 against 415 MiB, Boehm 547)
  with 0.40 padded at 429 and 0.39.0 padded at 437 MiB, and JsonParsePull
  +0.9%, the rows the keep-rule file found inside 0.39.0's padded peaks.

Kemal: `/json` 109.1% [104.7, 118.0] of Boehm at 1.36× (0.39.0: 108.2%,
1.39×), paired +0.2% [−5.9, +9.3]; `/` 103.4% [95.3, 114.5] at 1.38× (0.39.0:
99.5%, 1.40×), paired +4.5% [−8.5, +13.8]; peaks −1.6% and −1.7%; pause per
1 000 requests above.
