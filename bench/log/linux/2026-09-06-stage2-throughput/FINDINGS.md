# Stage 2: throughput at flat RSS (2026-09-06)

Linux x86_64 (WSL2, 24 cores), Crystal 1.21.0, `bench/performance/kemal_ab.py`,
Kemal `/json`, wrk 4 threads × 100 connections. Box quiet (load 0.01) apart from
an idle-weight 24 h soak on another checkout. Base tree: PR #34 head `3c05d4f`.

## Where the branch stood

Five arms, 20 rotated rounds of 15 s, Boehm null control 102.8% [97.8, 107.9]
(`basic/`):

| arm | req/s | % of Boehm [95% CI] | peak RSS × | faults/1k | CPU ms/10k |
|---|---|---|---|---|---|
| boehm | 45 796 | 100 | 1.00 | 1.4 | 240 |
| master headerless (`9bcd0e6`) | 40 101 | 88.1 [83.5, 92.7] | 1.69 | 1 239 | 251 |
| master header | 40 199 | 88.3 [84.7, 92.0] | 2.00 | 1 510 | 250 |
| PR #34 head headerless | 48 235 | 105.9 [101.2, 110.6] | 1.03 | 6.0 | 209 |

Main-thread PC profile under wrk (`pc_sample.py`, 5 000 samples at 2 ms):
libc/syscalls 64% (branch) and 70% (Boehm) of main-thread time; gcry symbols
9.5% against Boehm's 8.7% in `GC_*` plus ≈ 9% in its allocation lock and
condvar symbols. The remaining GC share was, by symbol:

| share | what |
|---|---|
| 3.7% | `GC::realloc` 1.7 + `chunk_search_unlocked` 1.1 + `chunk_containing` 0.9 |
| 3.0% | `alloc_old_small_locked` 1.8 + `allocate` 1.2 (10% of allocations left the hit path) |
| 2.4% | `malloc` / `malloc_atomic` (the inlined hit path, plus 3 out-of-line calls) |
| ≈ 1% | mark, collection body, sweep |

So the ceiling for GC-side work was about +10% and the target +4–6%.

Two of the twenty baseline rounds unmapped and re-mapped 74–125 MB in 15 s
(`unmapped_bytes`; the other eighteen 0–4 MB) and each lost ≈ 8%: the warm
budget equals the threshold, a cycle allocates the threshold, and the sweep
sat on that edge. `storm_probe.py` over a fresh 60 s process showed the
stable case (no unmaps); the storm is a per-process layout accident.

## What changed, each measured against the previous commit

Short paired runs at the author's request (8 rounds × 10 s for items 1–2,
3 rounds × 8 s for items 3–5), so the intervals are wide; CPU per request is
the steadier signal at this size.

| commit | change | req/s ratio [95% CI] | CPU ms/10k | RSS × |
|---|---|---|---|---|
| `c41a5e5` | realloc/free: owned-pointer lookup through the radix, fresh block from the cursor | 105.0 [97.4, 112.5] | 202 → 192 | 0.96 |
| `80a0cf3` | held cursor advances to the next word without the class lock; miss census | 106.4 [97.7, 115.1] | 207 → 195 | 0.98 |
| `431b194` `db81c73` `8bdddb5` | one-cycle grace before unmap; one TLS word and no hook call on the hit path; main-thread stack bounds cached | 113.3 [88.5, 138.0] (n = 3) | 224 → 199 | 1.01 |

Allocation microbench (`bench/micro/alloc_ns.cr`, 48 B, 5 M allocations):

| tree | 1 thread ns/alloc | 4 threads aggregate ns/alloc |
|---|---|---|
| Boehm (`alloc_boehm.cr`, same ring) | 131 | 135 |
| item 1 | 34.4–35.2 | 36.7 |
| tip (items 1–5) | 31.0–32.1 | 29.0 |
| item 2 tree with a plain occupancy store instead of the atomic OR | 31.5–34.7 | 29.7 |

## Declined with numbers

A plain store for the occupancy bit (plan item 4, third bullet) is worth
1–2 ns of the 32 and would let a concurrent cross-thread `free` lose its
clear against the cursor's store, which the counters would then double-count
at the sweep. Not taken.

The static-root soft-dirty skip (plan item 5) is bounded at 0.2 ms × 17
collections/s ≈ 0.3% of wall and needs its own red arm; the cheap half of
item 5 — the 106 µs `/proc/self/maps` parse behind `pthread_getattr_np` on
the initial thread at every stop — is the part that landed.

## Reproduce

`arms.json` in each subdirectory (paths rewritten to `<scratch>`), the
runner's `manifest.json` with source and binary hashes, `trials.jsonl`, and
the analyzer output. Profile with `pc_sample.py <pid> <binary> 5000 0.002`
against a server under wrk; the release counters per second with
`storm_probe.py <port> <seconds>`.
