# 0.36.0 against 0.35.0 and Boehm, native macOS (arm64 and x86_64)

GitHub runners, Crystal 1.21.0, `--release`:

- `macos-latest`: Apple M1 (Virtual), 3 vCPUs, 7 GiB, macOS 26 (Darwin 25.6),
  16 KiB pages.
- `macos-15-intel`: Intel Core i7-8700B, 4 vCPUs, 14 GiB, macOS 15 (Darwin
  24.6), 4 KiB pages.

The README's macOS table came from an M2 Pro laptop on 0.24.x (2026-09-06);
nothing in 0.36.0 had been measured off Linux.

## Method

`Perf A/B` (`.github/workflows/perf-ab.yml`, `bench/runner_ab/ab.sh`,
`ab.py`, `kemal_ab.py`), dispatched on branch `perf-native-0.36`, whose
`src/` is v0.36.0's (`git diff v0.36.0 -- src` is empty), with
`-f base=v0.35.0`. Three arms built in the job: Boehm (stock Crystal), 0.35.0
and 0.36.0. crystal-metric: 15 reps, every bench once per arm per rep,
process-fresh, random order, one discarded run per binary first. Cells are
medians of per-rep paired ratios with their interquartile range: speed is
Boehm's whole-process wall over the arm's; memory is the arm's peak resident
size (`wait4`'s `ru_maxrss`) over Boehm's. The method's floor, `true` measured
the same way, is 1.2 MiB on arm64 and 0.5 MiB on Intel. Every bench computed
the same result in every arm, Boehm's included.

Kemal (`bench/kemal`, every arm the same `server.cr`, only `lib/gcry/src`
swapped): 15 trials; per trial and path the three arms in random order, each
a fresh server, 3 s `wrk -t2 -c50` warm-up, then 10 s measured; peak RSS is
the server's `ru_maxrss` after SIGTERM. No CPU pinning: the runner's 3–4
vCPUs carry both `wrk` and the server, so absolute req/s are low and noisy,
and the per-trial paired ratio is the number to read.

Run [38723935225](https://github.com/sdogruyol/gcry/actions/runs/38723935225):
arm64 raw `arm64-runs.json`, `arm64-summary.md`, `arm64-kemal-runs.json`,
`arm64-kemal-summary.md`. The Intel job's first attempt finished but lost
its artifact to a network error at upload (`ENOTFOUND`); its printed summary
is `intel-attempt1-log-summary.md`, and attempt 2's raw data is `intel-*`.

## crystal-metric, macOS arm64

| bench | Boehm | 0.35.0 | 0.36.0 |
|---|---:|---|---|
| Primes | 0.883 s, 696 MiB | 102% [101, 103] / 0.89× | 100% [98, 101] / 0.88× |
| JsonParsePure | 1.168 s, 518 MiB | 91% [91, 93] / 1.08× | 93% [90, 93] / 1.08× |
| Binarytrees | 0.763 s, 39 MiB | 80% [79, 83] / 1.79× | 78% [77, 82] / 1.78× |
| JsonGenerate | 2.183 s, 1 198 MiB | 97% [94, 101] / 0.74× | 99% [97, 104] / 0.64× |
| JsonParseSerializable | 1.284 s, 498 MiB | 94% [93, 96] / 1.03× | 99% [98, 102] / 0.98× |
| JsonParsePull | 1.252 s, 521 MiB | 96% [93, 97] / 0.99× | 99% [97, 100] / 0.94× |
| Revcomp | 2.939 s, 834 MiB | 98% [97, 99] / 0.68× | 98% [98, 99] / 0.63× |
| RegexDna | 3.182 s, 534 MiB | 98% [97, 99] / 0.51× | 97% [97, 99] / 0.51× |
| Knuckeotide | 0.932 s, 47 MiB | 88% [87, 91] / 1.94× | 89% [87, 92] / 1.88× |

0.36.0 against 0.35.0, paired per rep (median [IQR]):

| bench | timed section | whole-process wall | peak RSS | Σ mark |
|---|---:|---:|---:|---:|
| Primes | +2.3% [+1.3, +3.3] | **+2.6% [+1.6, +3.4]** | −1.2% | +28.4% |
| JsonParsePure | −0.2% | −0.7% | −0.3% | −0.7% |
| Binarytrees | +2.0% | +1.9% [−1.1, +3.0] | −0.4% | −7.7% |
| JsonGenerate | −0.7% | −2.6% [−3.9, −1.7] | **−13.6%** | −8.2% |
| JsonParseSerializable | −5.3% | **−4.5% [−5.9, −2.8]** | −4.8% | −17.6% |
| JsonParsePull | −0.6% | **−3.3% [−5.9, −2.6]** | −5.3% | −16.8% |
| Revcomp | −1.2% | −0.7% | −6.0% | −9.1% |
| RegexDna | +0.6% | +0.6% | −0.0% | −1.6% |
| Knuckeotide | +0.3% | +0.1% | −3.3% | −7.2% |

- **The JSON rows gain, as on Linux.** JsonParseSerializable 94% → 99% and
  JsonParsePull 96% → 99% of Boehm, JsonGenerate's peak 0.74× → 0.64×: the
  in-place `realloc` growth of 0.36.0.
- **Primes is the one row slower beyond its spread: +2.6% wall, 102% → 100%
  of Boehm.** It is a shift of the collection schedule, not a cost per byte
  (below), and it reverses from one runner to the next.
- **Binarytrees runs at 78–80% of Boehm at 1.78× its peak on this runner, in
  both releases** (Linux 101% / 0.76×, Windows 94% / 0.94×). Not a 0.36.0
  change; not investigated here. [INFERENCE] Boehm's peak is 39 MiB, so the
  16 MiB Darwin threshold floor and the warm-chunk budget are most of
  gcry's 70 MiB, as for Knuckeotide (1.88×, 47 MiB).
- Revcomp's Windows regression (`../../windows/2026-10-15-0.36-native/`) does
  not appear here: −0.7% wall, −1.2% timed.

## crystal-metric, macOS x86_64 (Intel)

Attempt 2 of the same run (raw `intel-runs.json`, `intel-summary.md`), with
attempt 1's medians (`intel-attempt1-log-summary.md`) as a replicate:

| bench | Boehm | 0.35.0 | 0.36.0 | attempt 1: 0.35.0 → 0.36.0 |
|---|---:|---|---|---:|
| Primes | 2.059 s, 667 MiB | 85% [82, 90] / 0.91× | 90% [87, 94] / 0.91× | 86% → 91% |
| JsonParsePure | 2.940 s, 683 MiB | 89% [85, 94] / 0.85× | 92% [90, 95] / 0.81× | 84% → 92% |
| Binarytrees | 2.193 s, 36 MiB | 92% [91, 95] / 1.87× | 91% [90, 96] / 1.87× | 91% → 91% |
| JsonGenerate | 5.043 s, 1 194 MiB | 94% [91, 100] / 0.72× | 94% [91, 101] / 0.65× | 94% → 92% |
| JsonParseSerializable | 3.219 s, 547 MiB | 92% [90, 94] / 0.91× | 96% [90, 99] / 0.85× | 94% → 94% |
| JsonParsePull | 3.155 s, 512 MiB | 95% [92, 97] / 0.97× | 98% [97, 100] / 0.90× | 98% → 97% |
| Revcomp | 4.887 s, 987 MiB | 92% [89, 93] / 0.68× | 94% [89, 97] / 0.66× | 91% → 91% |
| RegexDna | 4.440 s, 542 MiB | 96% [94, 101] / 0.55× | 97% [95, 101] / 0.50× | 96% → 96% |
| Knuckeotide | 2.496 s, 45 MiB | 88% [86, 95] / 2.07× | 92% [87, 94] / 2.06× | 88% → 90% |

The Intel runner is 2–3× slower than the M1 and its spread is wider (IQRs of
5–10 points). No row is slower than 0.35.0 beyond it in either attempt.
JsonGenerate's timed section reads +3.7% [+0.6, +7.5] in attempt 2 and
+4.7% [−1.8, +14.0] in attempt 1, but its whole-process wall +0.3% and
−0.5%, inside the spread. Primes improves in both (wall −5.3% [−9.4, −1.6]
in attempt 2, Σ mark −22%; in the in-place flip run 0.35.0 and in-place-off
take 9 collections and 0.36.0 8, below), and every buffer-growing row's peak
drops 3–10%.

## Kemal

`macos-latest` (arm64):

| path | Boehm | 0.35.0 | 0.36.0 |
|---|---:|---:|---:|
| `/json` req/s | 84 036 | 102.8% [100.1, 103.5] | 102.1% [101.3, 102.9] |
| `/` req/s | 130 739 | 99.6% [98.0, 100.8] | 100.3% [99.7, 101.9] |
| peak RSS, `/json` | 15.0 MiB | 29.5 MiB (1.97×) | 29.2 MiB (1.94×) |
| peak RSS, `/` | 15.1 MiB | 29.2 MiB (1.93×) | 28.9 MiB (1.91×) |

Intel, attempt 2 (`intel-kemal-*`): `/json` 101.4% [96.8, 107.9] → 111.9%
[96.4, 117.2] at 2.21× → 2.20× (23.0 against 10.4 MiB); `/` 110.0% [94.2,
118.7] → 106.0% [92.9, 114.5]. Attempt 1: `/json` 108.0% → 108.7%, `/`
97.6% → 98.2%. Both paths' IQRs span ±10 points on this 4-vCPU runner, so
the Intel Kemal rows say "level with Boehm and with 0.35.0" and no more.

On arm64 0.36.0 is level with 0.35.0 on both paths. The peak is `ru_maxrss`, not the
laptop cut's peak footprint (`phys_footprint`, 1.50× in
`../2026-09-06-bitmap-default-ab/`), so the two are not comparable.
[INFERENCE] Resident size also counts `MADV_FREE_REUSABLE` pages the kernel
has not reclaimed yet, which footprint does not; and gcry's ~29 MiB is the
16 MiB Darwin threshold floor plus the warm-chunk budget against a 15 MiB
Boehm process, the floor the laptop cut also found (README "macOS"). The `/`
row moves with nothing the GC does: on Linux the GC is 0.3% of that run.

## Attribution: Primes and the collection schedule

The `var_env` arm runs the 0.36.0 binary with `GCRY_REALLOC_IN_PLACE=0`, so
code placement is identical. 20 reps, run
[38734279640](https://github.com/sdogruyol/gcry/actions/runs/38734279640)
(`attribution/inplace-r2-*`), 0.36.0 against its in-place-off arm on arm64:
wall +3.7% [+1.5, +5.6], Σ mark +26.4% [+23.2, +34.3], Σ scanned 615 against
510 MiB, 8 collections in both; 0.35.0 scans 510. On Intel the same flip
goes the other way: Σ mark −24.9%, 8 collections against 9, wall −6.0%
(`attribution/inplace-r2-intel-*`).

**The cause is where the collections fall.** Primes builds a trie whose
live set only grows, so Σ scanned is the sum of the live set at the
collection points. In-place growth charges the allocation counter only the
bytes a growth adds (`note_grow_bytes`), where a copy charged the whole new
block (`note_alloc_bytes`), so the collections move. Each collection's
scanned MiB, run
[38736749890](https://github.com/sdogruyol/gcry/actions/runs/38736749890)
(`attribution/primes-schedule-*`, 6 reps, first three shown), arm64:

| arm | scanned per collection (MiB) | collections | Σ (median) |
|---|---|---:|---:|
| 0.35.0 | 0, 0, 0, 40, 106, 269, 500, 0, 0 | 9 in 4 of 6 reps | 913 |
| 0.36.0 | 0, 0, 19, 44, 182, 346, 0, 0 | 8 in 6 of 6 | 579 |
| 0.36.0, in-place off | 0, 0, 0, 40, 114, 278, 515, 0, 0 | 9 in 5 of 6 | 902 |

On this runner 0.36.0 dropped the last, 500 MiB collection and scanned 37%
less, where on the main run's runner both releases took 8 and 0.36.0's
landed later (+20%). Linux shows the same split
(`attribution/linux-local-primes-*`, a 12-vCPU QEMU x86-64 host, 8 reps,
v0.35.0 and v0.36.0 binaries, `GCRY_LARGE_RECYCLE=0` arm included to mimic
Darwin's missing recycler): 9 collections → 8, Σ mark −22%, wall −3.7%
[−6.4, −1.7], and a per-collection trace of each (`*-trace-inplace-*.ndjson`)
with the last collection at 351 against 455 MiB scanned. So Primes's +2.6%
on the main arm64 run is a threshold-placement effect of a bench with a
monotonically growing heap, which favours or penalizes 0.36.0 by runner,
not more work per byte scanned.

Commit-by-commit dispatches (12 reps each, `bisect/<base>-*`; runs
38733021036, 38733031381, 38733041941, 38733051799, 38733062082,
38733071648) found nothing else on arm64: Revcomp and Brainfuck move within
their spread against every base (IQRs of ±5–15% on this runner), and Primes's
step does not follow any one commit (0.36.0 against `123069c3` +5.5% wall,
against `bfe05bd3` −2.8%, against `0a0e3165` −2.6%, against `f2f25ea2`
+1.4%).
