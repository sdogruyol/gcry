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
  retire, where 82 reorders two stores and adds a compiler fence. [INFERENCE] The five-runner rise is
  where the code lands, as in the Windows pad arms, not a cost of 81 or 82.

**Verdict:** no row is slower than 0.38.0 beyond what placement moves on the
same runner (Windows, macOS) or what the commits alone fail to reproduce
(Linux). JsonParseSerializable's Windows peak (0.87×) and every other row
stay inside the 1.1× budget; Knuckeotide reads 1.36–1.66× (0.38.0
1.43–1.68×), the documented exception (`../2026-10-21-knuckeotide-pin/`).

## Round 2, on `97c24df5` (2026-10-23)

Round 2 added the mprotect re-arm fix (regression 87; opt-in barrier, one
store in the fork reset on the default path), the incremental/TLAB frozen-class
fixes (regression 85; non-default paths), and the allocation slow path's tail
call with its stack wipe, clamped to the running fiber's guard page
(regression 86; default path, Windows keeps the old slow path).

- **Run 39810968089**, all five runners against `v0.38.0`, nine benches, 15
  reps, Kemal 15 trials. macOS, arm64 and Windows: no wall time slower beyond
  its spread except JsonParsePure +3.7% [+0.7, +6.3] on M1, JsonGenerate
  +1.7% [+0.3, +2.3] on arm64 and JsonParsePull +3.1% [+0.3, +10.2] on
  Windows; Knuckeotide's peak −16% on M1, −8% on arm64, −21% on
  `ubuntu-latest` (1.60× → 1.30× Boehm). `ubuntu-latest` read six rows slower,
  Binarytrees +4.2% wall [+2.6, +5.9] and RegexDna +2.7% the largest. Kemal
  `/json` is level on all four runners it runs on (paired spreads overlap; peak
  1.30–1.39× on both arms).
- **Run 39821365613**, the round-2 source changes alone (`97c24df5` against
  `07cc4a7f`, i.e. the guard-page clamp and the Windows split on top of the
  wipe), `ubuntu-latest` and arm64, nine benches: no row slower beyond its
  spread on either runner (largest: RegexDna's timed section +0.5% [+0.2,
  +1.7] on `ubuntu-latest`).
- **Run 39821365371**, `a47188df` (round 1 plus the mprotect fix, before the
  wipe) against `v0.38.0` on `ubuntu-latest`: Binarytrees +8.2% wall, the JSON
  rows +1.7 to +2.4%. Between `a04ce52a`, which read Binarytrees −1.9% on the
  same runner in 39671242540, and `a47188df` nothing on the mutator's path
  changed: the mprotect handler (unarmed by default) grew by 300 lines and the
  fork reset gained one call. The same code reads −1.9% and +8.2% depending on
  where it lands.
- **Run 39821292426**, `97c24df5` against `v0.38.0` on `ubuntu-latest` with pad
  arms: the JSON rows' and Revcomp's timed sections at 16 bytes of padding read
  what 0.38.0 reads (−4.0% to −5.2% against unpadded 0.39), and 0.38.0 padded
  by 16 reads what unpadded 0.39 reads (+0.8% to +1.0%). Binarytrees spans
  1.183–1.205 s padded against 0.38.0's 1.147–1.183 s; RegexDna 2.512–2.602
  against 2.488–2.561.

**Verdict:** none of round 2's changes carries a cost on the two Linux runners
when measured alone, and `ubuntu-latest`'s slower rows against 0.38.0 move with
padding and with code that never runs. [INFERENCE] Placement; Binarytrees on
`ubuntu-latest` is the row whose padded ranges overlap least and the first to
re-measure if it persists.

## Same-session check on `ubuntu-latest` (2026-10-24)

The verdict above compared runs from different days. Two runs now put each
tree beside `a04ce52a` (round 1 before the mprotect fix) in one session, with
pad arms, 15 reps:

- **Run 39918728529, `a47188df` against `a04ce52a`**, the pair with no change
  on the mutator's path. Binarytrees wall +1.2% [+0.0, +2.6], RegexDna +1.7%
  [+1.4, +1.8], Revcomp +3.2% [+3.1, +3.5] (timed section +9.3%). Code that
  never runs moves Revcomp by 9% here. Pads: 0.39 padded by 16 reads what
  `a04ce52a` reads on Binarytrees (1.172 against 1.181 s) and RegexDna (2.517
  against 2.518 s); on Revcomp `a04ce52a` padded by 16 reads 1.595 s, above the
  unpadded var's 1.562 s.
- **Run 39918732098, `6fc6665c` (the round-2 tree) against `a04ce52a`**.
  Binarytrees +0.5% [−0.9, +1.4], level. RegexDna +2.6% wall, with 0.39 padded
  by 16 at 2.518 s against `a04ce52a`'s 2.523 s. Revcomp +3.0% wall, the same
  as the no-change pair above, and `a04ce52a` padded by 16 reads 1.595 s
  against the unpadded var's 1.546 s. JsonParseSerializable, JsonParsePull and
  JsonParsePure are 1.2–1.5% faster.

In one session the Binarytrees rise is gone, and every row that still differs
moves as far with a pad or with code that never runs. That replaces the
[INFERENCE] above: `ubuntu-latest`'s slower rows against 0.38.0 are placement.

## Round 3, on `b888ac96` (2026-10-24)

Round 3 added the mark batch loop's inline small-object scan, the slow-path
wipe on every target (Windows included, three tail-call hops), atomic shared
byte counters, Darwin's executable found by its header, and regression 81's
rewrite. **Run 39944941478**, all five runners against `v0.38.0`, nine benches,
15 reps, Boehm, Kemal 15 trials, a 16-byte pad arm on each side:

- **macOS (both), arm64 and Windows:** no wall time slower beyond its spread.
  Faster beyond it: Binarytrees on M1 −5.4%, Intel −2.1%, arm64 −4.3%;
  JsonParseSerializable −5.1% on Intel; JsonParsePure −1.9% and JsonGenerate
  −2.0% on arm64; JsonParsePure −3.5%, JsonParsePull −2.3%, Revcomp −5.0% and
  RegexDna −2.3% on Windows. Knuckeotide's peak −13% Intel, −16% M1, −22%
  arm64. arm64's JsonParseSerializable and JsonParsePull peaks +1.4% and +1.6%
  beyond spread, at 0.86× Boehm.
- **`ubuntu-latest`:** six rows slower in wall time beyond their spread
  (Binarytrees +3.8%, JsonParseSerializable +2.3%, RegexDna +2.5%,
  JsonParsePull +2.2%, Revcomp +1.5%, JsonParsePure +1.0%). In the same
  session, 0.38.0 padded by 16 bytes reads what unpadded 0.39 reads on every
  one of them (−2.1% to +0.0% against it), and 0.39 padded by 16 moves
  −8.3% to +1.8%: placement, as in the same-session runs above.
  JsonParseSerializable's peak +5.0% [+1.2, +9.8], at 0.81× Boehm.
- **Kemal `/json`** level on all four runners it runs on.

Every row but Knuckeotide stays within 1.1× Boehm's peak; Knuckeotide reads
1.14–1.56× (0.38.0: 1.28–1.80× in the same run).

## Host load during local sessions (found 2026-10-23)

Three `bash -c 'while :; do :; done'` loops, left behind under the agent
harness on 2026-10-20 at about 07:10 UTC, kept three of the host's 12 vCPUs
busy until they were found and killed on 2026-10-23 at 19:30 UTC. Every local
session in that window ran beside them: the 0.38.0 Linux crystal-metric and
Kemal sessions the README quotes (`../2026-10-21-0.38-crystal-metric/`,
`../2026-10-21-0.38-kemal/`), the round-1 to round-3 local stress nights and
the agents' local A/B sessions. Interleaved arms shared the load equally, so
their paired differences stand; absolute times and the % of Boehm read on this
host carry it. The runner results in this file are unaffected. One header and
freelist `process_spec` run on 2026-10-23 failed four load-sensitive examples
(regressions 33, 51, 80) and passed four times in a row after.
