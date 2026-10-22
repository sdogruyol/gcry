# 0.39.0's tree against 0.38.0 on the five runners (keep rule), 2026-10-22

`release-0.39.0` at `a04ce52a` (the in-stop audit with its review fixes, the
dormant_flush and Knuckeotide findings, the stress tooling) against `v0.38.0`
(`9157672e`), `perf-ab.yml`, 15 reps, nine crystal-metric benches, Boehm on,
GC counters 3 runs. The only default-path source changes since 0.38.0 are the
cursor retire's store order (with a signal fence, regression 82), the heap
bounds recompute moving from the in-stop sweep into the release flush
(regression 81), and the large-release ledger's free flag (`segv_report`).

- **Run 39671242540**: all five runners. Wall time slower than 0.38.0 beyond
  its interquartile range: JsonParsePull +3.6% [+0.2, +5.4] on
  `macos-15-intel`, +0.3% [+0.1, +0.9] on arm64; JsonGenerate +0.9%
  [+0.4, +3.0] and Revcomp +2.7% [+2.5, +3.5] on `windows-latest` (Revcomp's
  timed section +15.4%, at the same collections, faults and Σ mark within
  +2.7%). Peak: JsonParseSerializable +8.6% [+1.0, +10.7] on Windows (0.80×
  → 0.87× of Boehm), Binarytrees +0.1% on Intel. Faster beyond spread on
  `ubuntu-latest`: JsonGenerate −1.5%, JsonParseSerializable −0.9%,
  JsonParsePull −1.1%, Revcomp −2.0%, RegexDna −1.0%.
- **Run 39682766187**: placement probe on Windows and both macOS runners,
  JsonGenerate, JsonParseSerializable, JsonParsePull and Revcomp, with
  0.39's source padded by 16 and 64 bytes ahead of all code (`p16`, `p64`)
  and 0.38.0's likewise (`bp16`, `bp64`). On Windows, Revcomp's timed
  section reads 1.056 s for 0.38.0, 1.198 s for 0.39, and **1.059 s for 0.39
  padded by 64 bytes** and 1.161 s for 0.38.0 padded by 64: the 11–15% is
  where the code lands, both ways round. JsonGenerate and JsonParsePull's pad
  arms spread −3.3% to +1.8% around the unpadded 0.39, wider than its
  difference from 0.38.0. On both macOS runners no wall time is slower beyond
  its spread in this run (JsonParsePull +3.7% [−0.9, +7.5] on M1, −0.2% on
  Intel).

- **JsonParsePull's timed section** was the one row slower on every runner
  in 39671242540: +1.1% [+0.4, +1.3] `ubuntu-latest`, +0.6% [+0.5, +1.6]
  arm64, +2.9% [+2.4, +3.6] Windows, +9.6% [+3.3, +23.2] M1, and +3.6% wall
  on Intel. Placement was probed on Windows and macOS only, so the two
  default-path commits were measured alone (15 reps, `ubuntu-latest`, arm64,
  Windows, M1; Primes, the JSON rows, Revcomp):
  - **Run 39702197449, regression 81 alone** (`9b72182e` against its parent
    `84a0259f`): JsonParsePull's timed section +0.3% [−0.1, +0.8], +0.9%
    [+0.5, +1.2], −0.6% [−2.0, −0.1], −4.5% [−8.0, −1.0].
  - **Run 39702200188, regression 82 alone** (`601bb973` against `9b72182e`):
    −2.4% [−2.7, −1.9], −1.6% [−1.7, −1.2], +0.7% [−0.9, +2.0], −3.7%
    [−8.9, +6.1].
  Neither commit moves the row the same way on two runners, and the two
  together come out faster as often as slower; the other rows flip sign the
  same way (Revcomp +6.4% timed on `ubuntu-latest` with 81, −0.3% with 82;
  JsonGenerate +1.9% on Windows with 81, −2.0% with 82). Nothing in either
  commit runs on the mutator's path in these benches except the cursor
  retire, which 82 makes no longer. [INFERENCE] The five-runner rise is
  where the code lands, as in the Windows pad arms, not a cost of 81 or 82.

**Verdict:** no row is slower than 0.38.0 beyond what placement moves on the
same runner (Windows, macOS) or what the commits alone fail to reproduce
(Linux). JsonParseSerializable's Windows peak (0.87×) and every other row
stay inside the 1.1× budget; Knuckeotide reads 1.36–1.66× (0.38.0
1.43–1.68×), the documented exception (`../2026-10-21-knuckeotide-pin/`).
