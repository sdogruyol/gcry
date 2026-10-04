# Parallel mark was slower than serial because of three shared writes

`GCRY_PARALLEL_MARK` made every crystal-metric mark slower, at every worker
count: +13% to +88% at 2 and 4 workers on 4-vCPU runners
(`../2026-10-03-mark-prefilter/parallel-mark-scaling.txt`), while Boehm's
default marker per CPU cuts its marks by ~4×. A SIGPROF profile of Primes
with four workers (`../2026-10-03-monitor-wait-spin/sampler.c`) found the
markers spending most of their time on cache lines other workers kept writing.

## 1. The push buffers' counts shared one line

Per-worker push buffers were two `StaticArray`s on `Heap` indexed by slot:
the buffer addresses (16 × 8 bytes) and their counts (16 × 4 bytes — all
sixteen in one 64-byte line). Every worker read its address and read and wrote
its count on every push (`samples-pm4-before.txt`): the count's read was 18.8%
of all CPU and the address's 18.5%. Each slot now has its own 128-byte stride
of one array, address and count together, so no two workers' words can share a
line however the array is aligned.

## 2. The radix hit counter shared a line with the radix root

`chunk_containing_unlocked` counts every radix hit in `@radix_fast_hits`, a
plain field beside `@radix_l1`, which every lookup reads first. With the push
buffers fixed (`samples-pm4-pushbuf.txt`), the read of `@radix_l1` was 26% of
all CPU. The hit and miss counters are diagnostics (`/gc-stats`,
`spec/chunk_radix_spec.cr`); they are no longer written while a parallel mark
runs.

## 3. `mark_noscan` took the global mark lock

Every `@entries` / `@indices` blob of a `Hash` is marked through
`mark_noscan`, which under parallel mark took `@mark_lock` for each one. The
lock dates from the first parallel mark (2026-07-24), when every mark took it;
the main path has marked without it since — a bitmap mark is an atomic OR and
a header mark stores the one generation value, and `mark_noscan` pushes
nothing. On JsonParsePure, after 1 and 2, four workers still marked +40% to
+54% slower than one. The lock is gone.

## Measured

Primes, local (12 vCPUs, a campaign on 5 of them), Σ mark, best of 2:

| tree | 1 worker | 4 workers |
|---|---:|---:|
| before (`26bf753`) | 1158 ms | 3541 ms |
| + 1 | 1157 ms | 2036 ms |
| + 1, 2 | 1166 ms | 585 ms |

JsonParsePure, same host: + 1, 2: 1517 / 3727 ms; + 1, 2, 3: 1593 / 682 ms.

All three, 4-vCPU GitHub runners, 6 interleaved reps (`parallel-mark-scaling.sh`,
`scaling-after.txt`), Σ mark against one worker (before → after):

| bench | 4 workers, x86-64 | 4 workers, aarch64 |
|---|---:|---:|
| Primes | +45% → **−45%** | +61% → **−43%** |
| JsonParsePure | +52% → **−53%** | +88% → **−62%** |
| Binarytrees | +26% → **−47%** | +19% → **−61%** |
| JsonGenerate | +39% → **−21%** | +42% → **−44%** |

JsonParsePure's timed section drops from 1.57 to 1.00 s on x86-64 and from
2.14 to 1.26 s on aarch64 with four workers. One worker is unchanged
(serial mark never touched the push buffers, and the counters still count).

## Gates

`crystal spec` (headerless and `-Dgcry_block_headers`), `process_spec` (both),
`make parallel-mark-termination parallel-mark-stress parallel-mark-process
mark-audit nursery-headers bitmap-marks-freelist`, `ci/sound-suite.sh`,
`stw_mt` with `GCRY_PARALLEL_MARK=4` 60 runs each layout, `thread_storm` with
it 60 runs: all green; Darwin and Windows type-check.

## Not changed

Parallel mark stays opt-in. The HTTP picture (`GCRY_PARALLEL_MARK` in
HARDENING: Kemal throughput regressed with it) was measured before these fixes
and is not re-measured here, and a default change needs that and a campaign.
