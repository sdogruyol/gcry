# `readiness` vs `master` vs Boehm — the numbers behind the PR

Host: QEMU x86-64 guest, 12 vCPUs, 11 GiB, Linux, Crystal 1.21.0, `--release`.
Arms: Boehm (stock Crystal), gcry at `master` (`6650b80`), gcry at `readiness`
(`25934c6`). Binaries built once, run on an otherwise idle machine.

## crystal-metric, process-fresh, 11 interleaved trials, all 12 CPUs

`crystal-metric-summary.txt` / `crystal-metric-raw.json`
(`bench/log/linux/2026-10-05-alloc-storm-mark/ab.py`; one fresh process per
bench, arm order shuffled per trial). Speed is Boehm wall ÷ gcry wall (median).

| bench | master | readiness | peak RSS MiB master / readiness / Boehm |
|---|---:|---:|---|
| Primes | 42% | **100%** | 593 / 618 / 659 |
| JsonParsePure | 43% | **99%** | 545 / 551 / 686 |
| JsonParseSerializable | 92% | **100%** | 474 / 413 / 573 |
| JsonParsePull | 93% | 96% | 474 / 416 / 524 |
| JsonGenerate | 107% | **113%** | 868 / 763 / 1200 |
| Binarytrees | 82% | **94%** | 22 / 38 / 51 |
| RegexDna | 100% | 102% | 272 / 272 / 513 |
| Revcomp | 84% | **94%** | 559 / 527 / 885 |
| Knuckeotide | 95% | 96% | 55 / 60 / 40 |
| Brainfuck | 97% | 98% | 5 / 5 / 5 |
| Brainfuck2 | 101% | 101% | 6 / 5 / 5 |
| Matmul | 100% | 101% | 36 / 37 / 30 |
| Threadring | 107% | 108% | 8 / 8 / 7 |

CPU time (user+sys, median) on the collection-bound rows, readiness vs Boehm:
Primes 0.86 vs 1.14 s, JsonParsePure 1.08 vs 1.59 s, JsonGenerate 1.86 vs
2.29 s — Boehm's parallel marker uses every CPU; gcry's uses `CPUs/4+1`.

Where it came from (each with its own findings directory):
`2026-10-05-alloc-storm-mark` (size class in mark entries, futex wake, worker
count), `2026-10-06-threshold-pacing` (fewer majors when collections dominate),
`2026-10-06-mark-cost` (inline candidate resolution, payload prefetch),
`2026-10-06-realloc-page-move` and `2026-10-06-large-recycle` (page faults).

## Kemal, 11 interleaved trials, server on CPUs 8-10, `wrk -t1 -c50` on CPU 11

| path | Boehm | master | readiness |
|---|---:|---:|---:|
| `/json` req/s (% Boehm) | 44 680 | 45 973 (102.9%) | 45 585 (102.0%) |
| `/` req/s (% Boehm) | 145 912 | 138 077 (94.6%) | 126 589 (86.8%) |
| peak RSS (`/json`) | 15.6 MiB | 21.0 MiB | 22.3 MiB |
| RSS after `GC.collect` | 15.6 MiB | 13.8 MiB | 13.8 MiB |

`/` is not GC-bound and the drop is code placement, not collector behaviour:

- The GC is 0.3% of the run: 204 majors, 29.5 ms total pause in 10 s
  (master: 241, 28.8 ms). Minor faults are equal (2 887 vs 2 882 in 6 s), as
  are the main thread's CPU split and context switches.
- No knob moves it (`kemal-root-knobs2.txt`): old stack lags, serial mark,
  no atomic slack, no pacing, no page moves/recycling all land at 87–90% of
  master, like the default.
- The same `readiness` code with only a block of NOPs inserted in an
  init-time function (`kemal-root-layout.txt`) reads 91%, 98% and 94% of
  master: ±7% from layout alone, the same order as the gap. A per-commit
  bisect (`kemal-root-bisect.txt`) is not monotonic for the same reason.
