# The bitmap default on Darwin: the five-arm paired run

The Linux decision (`bench/log/linux/2026-09-06-bitmap-default-ab/`) was
taken with no Darwin host. This is the same protocol on one: tree `f43d2bc`
(master at the 0.24.0 cut; the working tree carried the Darwin port of the
runner and two harness edits, none under `src/`, listed in `manifest.json`
`dirty`), `bench/performance/kemal_ab.py`, Kemal `/json`, 20 rotated rounds
× 5 arms, 15 s per trial after a 3 s warmup, `wrk -t4 -c100`,
identical-binary null control. `arms.json`, `manifest.json`, `trials.jsonl`
and both analyses are beside this file. Host: Apple M2 Pro (10 cores, 16 GB,
16 KiB pages), Darwin 25.6.0, Crystal 1.21.0, EC1. load1 5.1–5.3 through the
run, which is the run itself (wrk's four threads plus the server); the null
arm says what that cost.

The bitmap arm is the process default as shipped (`env: {}`); the header arm
is the escape, `GCRY_BITMAP_ALLOC=0`. Per-process counters come from libproc
here rather than `/proc`: **peak RSS ×** is the lifetime high-water mark of
`phys_footprint`, which Darwin drops a page out of at `MADV_FREE_REUSABLE`
time; post-GC RSS is the resident size, which it does not.

## Result

Against Boehm (`analysis_boehm.txt`):

| arm | req/s | ratio [95% CI] | t | peak RSS × | faults / 1k req | CPU ms / 10k |
|---|---:|---:|---:|---:|---:|---:|
| boehm | 59 546 | 100.0% | | 1.00 | 0.3 | 183.0 |
| null (same binary) | 60 057 | 100.9% [99.1, 102.6] | 1.06 | 0.96 | 0.3 | 182.9 |
| **header** (`GCRY_BITMAP_ALLOC=0`, the escape) | 50 925 | **85.5%** [84.6, 86.4] | −33.99 | 1.78 | **344.3** | 195.6 |
| **bitmap** (the shipping default) | 60 607 | **101.8%** [100.5, 103.1] | 2.98 | **1.97** | 0.8 | 164.3 |
| headerless (`-Dgcry_headerless`) | 60 686 | **101.9%** [100.9, 103.0] | 3.80 | 1.50 | 0.4 | 164.0 |

Against the freelist (`analysis_header.txt`): bitmap is **119.0% [118.0,
120.0]** of it at **1.10× its peak footprint**; headerless **119.2% [117.7,
120.7]** at 0.84×.

By phase (medians; KiB; latency from wrk):

| arm | peak footprint | resident at end of load | post-GC resident | p50 µs | p99 µs | pause p50 ms | majors / 15 s | threshold MiB | warm budget MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| boehm | 21 296 | 23 464 | 23 464 | 1 660 | 2 925 | | | | |
| header | 40 480 | 31 872 | 25 096 | 1 895 | 5 155 | 0.744 | 280 | 16.0 | 0 |
| bitmap | 44 440 | 46 712 | 28 264 | 1 630 | 3 005 | 0.572 | 322 | 16.5 | 16.5 |
| headerless | 33 560 | 35 784 | 23 136 | 1 625 | 2 935 | 0.565 | 324 | 16.5 | 16.5 |

The short smoke (`bench/perf_smoke.sh`, `wrk -c50 -d5`, 5 runs trimmed,
same binaries' flags) agrees: default **101.3%** of Boehm on `/json`, 99.3%
on `/`, post-`/gc-collect` RSS 1.275×, pause p50 0.367 ms
(`../2026-09-06-173014/`); `GCRY_BITMAP_ALLOC=0` **88.4%** / 87.9% at 1.202×
and 0.419 ms (`../2026-09-06-173333/`).

## What it says

1. **Throughput reads as it did on Linux.** The bitmap default is at Boehm
   parity (101.8%, CI just above 100) with 10% less CPU per request than
   Boehm and 16% less than the freelist, Boehm's fault count (0.8 per 1 000
   requests against the freelist's 344), a p99 at Boehm's (3.0 ms against
   the freelist's 5.2) and a shorter pause (0.57 against 0.74 ms). The
   freelist is 85.5% of Boehm here, not the 74.9% it was on Linux: its
   Darwin threshold is 16 MiB against 32 there (HARDENING.md; 16.0 MiB
   median on `/gc-stats` in this run), so it collects at half the heap,
   which is also why its peak is lower.
2. **RSS does not read as it did on Linux.** There the bitmap arm's peak was
   0.69× the freelist's; here it is **1.10×** (1.97× against 1.78× Boehm),
   and post-GC resident 28.3 against 25.1 MB. The freelist releases every
   emptied chunk with `MADV_FREE_REUSABLE`, which leaves the footprint at
   once, so its high-water mark is the live set plus one threshold of
   garbage; the bitmap arm keeps a warm budget equal to the threshold
   (16.5 MiB here) on top of that. On Linux the freelist ran at 32 MiB and
   peaked at 54 MB, above the bitmap arm's 37.5; here both arms run at
   16 MiB and the warm budget is the difference. On the arms that hold
   their peak (Boehm, bitmap, headerless) resident at the end of the window
   sits 2.2–2.3 MB above the footprint peak: the file-backed pages the
   footprint does not count. The freelist's 31.9 MB is below its 40.5 MB
   peak for the same reason its peak is lower — the mark is a high-water
   mark and the releases are immediate.
3. **Headerless is the best arm on every column again**, at 1.50× peak and
   0.99× post-GC.
4. The null control (100.9% [99.1, 102.6]) puts this box at ±1.8 pp on a
   paired ratio; every gap above is outside it.

## Against the product bar

`/json ≥95% @ ≤1.0× RSS`: the default passes the first half and misses the
second at 1.97× peak footprint (1.20× post-GC resident). The escape misses
both (85.5% at 1.78×). The lever is the same as on Linux — the warm budget
follows live × `GCRY_THRESHOLD_FACTOR`, capped by the threshold — and on
Darwin the 16 MiB threshold floor is that cap for a heap this size, so the
factor alone will not move it; the floor is the next thing to measure.

## Recommendation

Ship the default on Darwin as on Linux. Every column but peak footprint is
better than the escape, and the footprint costs 10% against a 19% throughput
gap and a 430× fault gap. Record the Darwin RSS numbers as their own row
(PERF-macos.md), not as the Linux ones.

## Not measured here

EC4 (`EC_PARALLELISM>1`, fixed 64 MiB threshold). acikturkiye on Darwin.
The 16 MiB Darwin threshold floor against RSS — the cut that would say
whether a lower floor buys the footprint back at this throughput.
