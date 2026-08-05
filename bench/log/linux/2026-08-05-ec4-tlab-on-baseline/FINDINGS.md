# Parallel TLAB-on tip baseline — Phase A

**Date:** 2026-08-05 · Host: WSL2 **R9-9950X** · Crystal 1.21.0  
**Branch:** `plan/parallel-tlab-on` @ `edf96c3` (+ harness)  
**Plan:** [docs/PARALLEL_TLAB_ON.md](../../../../docs/PARALLEL_TLAB_ON.md)

## Results

| Gate | Config | Result | Notes |
|------|--------|--------|-------|
| **A1** | `stw_mt_property_test --tlab` (± nursery) w=2,4 | **PASS** | CI-shaped |
| **A2** | Soft-soak EC4 TLAB-**off** N=40 d=8 `/json` | **PASS** 40/40 soft=0 hard=0 | thr med **~107.7k** → `a2-tlab-off/` |
| **A3** | Soft-soak EC4 TLAB-**on** N=40 d=8 `/json` | **PASS** 40/40 soft=0 hard=0 | thr med **~52.7k** (~**49%** of off) → `a3-tlab-on/` |
| **A4** | Quiet Kemal EC4 med-of-3 d=30 | **done** | see below |

### A4 quiet (same host, `EC_PARALLELISM=4`)

| | Session | `/json` gcry abs | RSS × Boehm | Note |
|--|---------|-----------------:|------------:|------|
| TLAB-**off** | `2026-08-05-113313/` | **~107.9k** | **~5.97×** | supported shape |
| TLAB-**on** | `2026-08-05-114156/` | **~48.0k** | **~126×** | hit rate ~98%; heap ~**1.9 GiB** |

**Do not cite % of Boehm** from these cuts — Boehm EC4 thr was soft (~41–45k
`/json`); use **gcry abs** and RSS × for off/on compare.

gcstats `/json` med trial (indicative):

| | TLAB-off | TLAB-on |
|--|---------:|--------:|
| collections | 280 | 131 |
| small_mapped | ~93 MiB | ~**1.86 GiB** |
| size_class chunks | 743 | **15236** |
| fully_free_chunk_bytes | ~77 MiB | ~**1.84 GiB** |
| released_chunk_bytes | 0 | 0 |
| tlab_hit_rate | — | **98%** |

Parallel default keeps empty munmap **off** — TLAB-on maps many chunks then
leaves empties resident → RSS cliff. Soft-soak (A3) only gates soft/hard
errors, **not** RSS.

## Harness

- `SOFT_SOAK_ALLOW_TLAB=1` / `make soft-soak-ec4-tlab` for A3.
- Default `soft_soak_ec4.sh` still refuses accidental `GCRY_TLAB=1`.

## Verdict

1. **Crash/soft correctness tip is quiet** (A1–A3 green) — no forced Phase B
   for SEGV/mark-miss.
2. **TLAB-on is not product-credible yet:** thr ~½ of TLAB-off **and** quiet
   RSS ~**20×** worse than supported Parallel (~6× → ~126×).
3. **Next = Phase B′ (RSS / reclaim under TLAB)** before thr micro-opts:
   why so many chunks; can empties dormant/DONTNEED without
   `PARALLEL_RELEASE` hang class; do not flip Parallel munmap default.
4. Supported TLAB-off path remains green (A2 + A4 off ~6×).

## Next

1. Phase **B′** — RSS anatomy + safe reclaim under TLAB-on (research knobs
   only; re-run A2 after any code change).
2. Phase **C** thr residual only after quiet RSS is in a shippable band
   (e.g. ≤ ~2× TLAB-off Parallel RSS, TBD).
