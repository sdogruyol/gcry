# crystal-metric on 0.38.0 against 0.37.0 and Boehm (Linux)

`release-0.38.0` at `8b9e7eab` against `v0.37.0` (`16b7e67c`) and Boehm, one
binary per arm, built as `bench/run_crystal_metric_ab.sh` builds them
(`--release`; `-Dgc_none` for gcry), Crystal 1.21.0. QEMU x86-64 guest, 12
vCPUs. `../2026-10-14-rss-budget-recheck/ab.py`: every (rep, bench) runs each
arm once in random order; whole-process wall time and `ru_maxrss`, medians;
paired deltas are per rep, 0.38.0 over 0.37.0, median [IQR]. Each session held
the host-wide lock. The JsonParsePure checksum mismatch (`err result=…`, 77
per arm per session) is the same in every arm, Boehm's included.

The tree measured is `8b9e7eab`. The commits after it to the release
(`69bd6a2e` and its findings, docs) change only what the sweep inside a stop
does while a frozen thread holds the chunk list lock; these benches run the
default lazy sweep, so the numbers stand for the release [INFERENCE: not
re-measured on the later tip].

- `session1.md` / `session1-runs.json`: 11 reps, 2026-10-20 evening, while
  two agents' builds ran outside the lock. Noisy: Brainfuck, which allocates
  nothing, reads 3.8% apart between the two gcry builds and Boehm's IQR is
  ±8% on it.
- `session2.md` / `session2-runs.json`: 11 reps, after midnight, quiet
  (Brainfuck −0.2% [−2.9, +1.8]). The README table.

Session 2, speed as % of Boehm / peak RSS × Boehm:

| bench | Boehm | 0.37.0 | 0.38.0 | wall, 0.38.0 vs 0.37.0 | peak, 0.38.0 vs 0.37.0 |
|---|---:|---|---|---:|---:|
| Primes | 0.703 s, 659 MB | 104% / 0.94× | 107% / 0.94× | −1.7% [−3.5, +0.2] | 0.0% |
| JsonParsePure | 0.873 s, 689 MB | 103% / 0.81× | 102% / 0.81× | +0.4% [−1.7, +2.2] | −0.2% |
| Binarytrees | 0.552 s, 50 MB | 99% / 0.74× | **114%** / 0.74× | **−11.2%** [−13.9, −10.7] | 0.0% |
| JsonGenerate | 1.605 s, 1228 MB | 104% / 0.63× | 105% / 0.63× | −1.5% [−3.4, +0.4] | +0.1% |
| JsonParseSerializable | 0.907 s, 572 MB | 104% / 0.71× | 106% / 0.71× | −0.5% [−1.4, +1.7] | 0.0% |
| JsonParsePull | 0.897 s, 540 MB | 104% / 0.76× | 105% / 0.76× | −0.3% [−1.3, +0.8] | 0.0% |
| RegexDna | 2.430 s, 453 MB | 98% / 0.60× | 99% / **0.48×** | 0.0% [−2.4, +1.9] | **−19.2%** |
| Revcomp | 2.021 s, 849 MB | 96% / 0.62× | 97% / 0.62× | +0.4% [−2.3, +0.7] | 0.0% |
| Knuckeotide | 0.720 s, 40 MB | 99% / 1.45× | 100% / **1.71×** | −3.0% [−3.7, +0.5] | **+20.9%** [+14.2, +28.4] |
| Brainfuck | 2.634 s, 14 MB | 98% / 1.00× | 99% / 1.00× | −0.2% [−2.9, +1.8] | 0.0% |

Session 1 agrees: Binarytrees −13.9% [−23.0, −8.8], Primes −8.8%, RegexDna's
peak −19.2%, Knuckeotide's peak +17.2% [+2.5, +24.2]; Revcomp +1.6%
[−5.6, +7.0] and JsonGenerate +0.2% [−4.6, +5.9], both inside their spread.

**Slower or heavier than 0.37.0 beyond its spread:** Knuckeotide's peak RSS
only, in both sessions (57 → 68 MB). That is the dead buffer pinned by a word
in crystal-metric's own `Benchmark::run` frame, whose layout changes with the
claim's inlining (`../2026-10-19-occupancy-claim-038/`), and Knuckeotide is
the documented exception to the 1.1× RSS budget. No wall time is slower
beyond its spread in either session.

**Faster:** Binarytrees by 11–14% is the occupancy claim — the allocation hit
path no longer does a locked OR per block. RegexDna's 19% lower peak comes
with the claim too, not with the allocation-entry frame fix: 5 interleaved
reps of RegexDna alone (`regexdna-bisect.md`) read 270–271 MB on 0.37.0, on the
tree before the frame fix (`4fc3fe53`), at the fix (`c2dd2226`) and on the
last tree before the claim (`d2594ff8`), and 219 MB at `8b9e7eab`. What in
the claim lowers it — a shifted collection schedule or a frame that no longer
pins a dead buffer — is not attributed.
