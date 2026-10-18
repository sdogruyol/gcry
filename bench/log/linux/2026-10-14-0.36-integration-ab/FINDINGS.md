# 0.36.0 integration against 0.35.0 and Boehm

Linux x86_64, 12 vCPUs (QEMU guest), Crystal 1.21.0, `--release`. Master is
`b18d5c8` (0.35.0). Every measured run held a host-wide lock, so no other job
ran beside it.

## crystal-metric

`../2026-10-14-rss-budget-recheck/ab.py`: 7 reps, every arm once per (rep,
bench) in random order. Whole-process wall time (setup included) and
`ru_maxrss`, medians; cells are speed as % of Boehm / peak RSS × Boehm.
Checksum mismatches (`err result=…`) are the same in every arm, Boehm's
included.

**Final: `release-0.36.0` at `48e7c74`** (`final-table.md`, `final-runs.json`):

| bench | Boehm | 0.35.0 | 0.36.0 |
|---|---:|---|---|
| Binarytrees | 0.561 s, 51 MB | 102% / 0.77× | 101% / 0.76× |
| Primes | 0.699 s, 659 MB | 97% / 0.93× | 101% / 0.93× |
| JsonParsePure | 0.873 s, 691 MB | 98% / 0.83× | 102% / 0.80× |
| JsonGenerate | 1.626 s, 1231 MB | 101% / 0.70× | 106% / 0.63× |
| JsonParseSerializable | 0.909 s, 533 MB | 102% / 0.93× | 106% / 0.77× |
| JsonParsePull | 0.875 s, 523 MB | 98% / 0.95× | 103% / 0.79× |
| RegexDna | 2.423 s, 513 MB | 100% / 0.53× | 98% / 0.53× |
| Revcomp | 1.996 s, 885 MB | 95% / 0.63× | 92% / 0.60× |
| Knuckeotide | 0.685 s, 40 MB | 96% / 1.72× | 96% / 1.79× |
| Brainfuck (allocates nothing) | 2.579 s, 14 MB | 99% / 1.00× | 98% / 1.00× |

Earlier the same day, at `a5e52df` (before the `bytes_since_gc`, tripwire and
large back-link commits; `table.md`, `runs.json`), Revcomp read 96% for 0.35.0
and 97% for the branch.

**Revcomp's −3 points are code placement, not the changes**
(`attribution-table.md`, `attribution-runs.json`, 9 reps). Binaries at
`6dc6e7d`, `b1cdc0ed` and `48e7c74` read Revcomp 2.072 / 2.104 / 2.170 s.
Brainfuck, which allocates nothing and so cannot see any collector change,
read 2.623 / 2.543 / 2.668 s, a 5% swing between the last two builds.
Revcomp over Brainfuck is 0.790 / 0.827 / 0.813, against 0.798 for 0.35.0.

`../2026-10-15-revcomp-attribution/` confirms this with counts. perf has no
counters here: the guest has no PMU and `perf_event_paranoid` is 4.

- callgrind: 0.36.0 runs 0.14% *fewer* instructions on Revcomp than 0.35.0.
  gcry's code is 2.8–3.0% of the instructions in every build. The
  back-link's unlinks are 25 per run and walk 0 steps.
- gcry's counters are identical across the 0.36.0 commits: 22 collections,
  2.1–2.4 ms of total pause, 14 in-place grows.
- v0.36.0's own source, rebuilt with 16 or 2 096 bytes of nops in front of
  the program's code, moves Revcomp 2.144 ↔ 2.019 s (6.2%) in two sessions.
- Revcomp's timed section is 4–5% *faster* than 0.35.0's in every session.

- The JSON rows that grow buffers gain 4–5 points and lose 10–17% of peak RSS
  (in-place growth).
- Every row except Knuckeotide is under Boehm's peak; Knuckeotide is a 40 MB
  process whose peak is the threshold floor and warm budget
  (`../2026-10-14-rss-budget-recheck/`).

## Kemal

`kemal_ab.sh`: server on CPUs 0–2, `wrk -t4 -c50` on CPUs 3–11, 3 s warm-up,
10 s measured, 9 trials with the arms in random order per trial and path;
req/s and the server's `VmHWM`, medians (`kemal-summary.txt`,
`kemal-results.tsv`).

| path | Boehm | 0.35.0 | 0.36.0 |
|---|---:|---:|---:|
| `/json` req/s | 42 860 | 44 978 (104.9%) | 45 169 (105.4%) |
| `/` req/s | 68 553 | 69 080 (100.8%) | 68 508 (99.9%) |
| peak RSS | 16.0 MB | 21.3 MB (1.33×) | 21.0 MB (1.31×) |

At `6dc6e7d` (`kemal-results-6dc6e7d.tsv`): `/json` 103.5% and 103.6%, `/`
101.7% and 97.9% (branch, 0.35.0) — the same picture within the spread
(`/` ranges 64–88k req/s per trial).
