# Phase B′ — TLAB-on RSS anatomy + dormant A/B

**Date:** 2026-08-05 · Host: WSL2 R9-9950X · Crystal 1.21.0  
**Branch:** `plan/parallel-tlab-on`  
**Plan:** [docs/PARALLEL_TLAB_ON.md](../../../../docs/PARALLEL_TLAB_ON.md)

## Anatomy (why ~126×)

1. **Parallel empty reclaim default off** — under EC>1,
   `release_empty_chunks_this_collect?` is false unless `PARALLEL_DORMANT*` /
   `PARALLEL_RELEASE`. Empties stay mapped.
2. **TLAB amplifies mapped empties** — A4: ~15k chunks / ~1.9 GiB,
   `fully_free ≈ heap`, hit rate ~98%.
3. **`sweep_after_world?` false when TLAB on** — in-STW sweep; fewer majors
   (secondary).
4. **Linux `empty_chunk_retain=0`** — bounded dormant needs
   `GCRY_EMPTY_CHUNK_RETAIN` (same recipe as TLAB-off Parallel RSS opt-in).

## Results

| Config | Session | `/json` gcry abs | RSS × | Notes |
|--------|---------|-----------------:|------:|-------|
| TLAB-on alone (A4) | `…-114156/` | **~48.0k** | **~126×** | control cliff |
| TLAB-off Parallel (A4) | `…-113313/` | **~107.9k** | **~5.97×** | supported |
| **B1** TLAB + `PARALLEL_DORMANT=1` + retain **32 MiB** | `…-115941/` med3 | **~57.6k** | **~3.47×** | `/` ~128k @ **4.05×** |
| B1 t1 smoke | `…-115715/` | ~57.0k | **3.55×** | dormant bytes ~70 MiB in gcstats |

Soft-soak B1 recipe N=20: see `b1-soak20/` (below).

**% Boehm** from these cuts is noisy (Boehm EC4 soft); prefer **gcry abs** and RSS ×.

### gcstats contrast (`/json`)

| | A4 TLAB-on | B1 dormant32 |
|--|----------:|-------------:|
| heap | ~1.86 GiB | ~**140 MiB** |
| chunks | ~15k | ~**1.1k** |
| dormant_chunk_bytes | 0 | ~**70 MiB** |
| released | 0 | 0 |

## Soft soak

| Config | N | Result |
|--------|--:|--------|
| TLAB-on alone (A3) | 40 | 40/40 soft=0 hard=0 · thr ~53k |
| B1 TLAB+dormant32 | 20 | **PASS** 20/20 soft=0 hard=0 · thr med **~56.3k** |

## Verdict

- **RSS cliff is reclaim policy, not a TLAB freelist bug.** Existing opt-in
  `GCRY_PARALLEL_DORMANT=1` + `GCRY_EMPTY_CHUNK_RETAIN=33554432` closes it:
  ~**126× → ~3.5×** on `/json`, thr holds ~**58k** (still ~½ of TLAB-off).
- **No process-default change** this pass. Research recipe for TLAB-on Parallel:
  ```
  EC_PARALLELISM=4 GCRY_TLAB=1 \
    GCRY_PARALLEL_DORMANT=1 GCRY_EMPTY_CHUNK_RETAIN=33554432
  ```
- **Do not** enable `PARALLEL_RELEASE`.
- Next: Phase **C** thr residual (hit/`find_block`) **or** document+warn that
  `GCRY_TLAB=1` under Parallel without dormant is an RSS footgun; optional
  auto-enable bounded dormant when TLAB∧EC>1 (product decision, separate PR).

## Artifacts

- `b1-med3-console.log` → session `2026-08-05-115941/`
- `b1-t1-console.log` → `2026-08-05-115715/`
- `b1-soak20/` + console
- Incomplete aborted med3 attempt: `2026-08-05-115327/` (ignore)
