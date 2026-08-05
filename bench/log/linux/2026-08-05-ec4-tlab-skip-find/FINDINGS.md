# Phase C.3 — `find_block` elision on TLAB hit — **KEEP (research opt-in)**

**Date:** 2026-08-05 · Host: WSL2 R9-9950X · Crystal 1.21.0  
**Branch:** `plan/parallel-tlab-on`  
**Plan:** [docs/PARALLEL_TLAB_ON.md](../../../../docs/PARALLEL_TLAB_ON.md)

## Lever

`GCRY_TLAB_SKIP_FIND_BLOCK=1` — skip `find_block` on `tlab_alloc_small` hit
(stderr warn). Heads trusted while empty chunks stay mapped (Parallel
reclaim-off / dormant). **Not** safe with `PARALLEL_RELEASE` / EC1 munmap
empty reclaim (historical SEGV).

## Method

Binary `/tmp/kemal-gcry-c3` (`-Dgc_none --release`). Recipe B1:
`EC_PARALLELISM=4 GCRY_TLAB=1 GCRY_PARALLEL_DORMANT=1
GCRY_EMPTY_CHUNK_RETAIN=33554432`. Load `wrk -c100 -d20 -t4 /json` (med3);
soft-soak N=20 d=8.

## Results

### Quiet thr (med-of-3, noattr)

| Config | trials (req/s) | **median** |
|--------|----------------|----------:|
| B1 control (find_block on) | 52.8k / 52.9k / 53.4k | **52 875** |
| B1 + skip | 63.1k / 63.3k / 65.2k | **63 287** |

**+19.7%** vs same-day control (~**+10%** vs B′ quiet ~57.6k).

Still ~**59%** of A4 TLAB-off quiet (~107.9k) — gap not closed.

### Attr composition (B1+skip+attr)

| | C.1 (find on) | C.3 skip |
|--|-------------:|---------:|
| wrk (attr tax) | ~47k | ~55k |
| lock wait avg | ~193 ns | **~76 ns** |
| lock hold avg | ~141 ns | **~72 ns** |
| find_block calls | ~1/hit | **0** |

Hold halves as expected; wait also drops (shorter hold → less slot
contention; no `@index_lock` on hit).

### Soft soak

| Config | N | Result | thr med |
|--------|--:|--------|--------:|
| B1 + skip | 20 | **PASS** 20/20 soft=0 hard=0 | **~68.9k** |

### TLAB-off smoke

Single d=20: ~81k (host soft vs A4 ~108k). Skip is TLAB-only — no code path
on off. No same-harness med3 off today.

## Verdict — **KEEP research opt-in**

1. Real thr win under B1 (~**+20%** med3) with soak green.
2. Stay **opt-in** + warn; do **not** default-on (munmap UAF footgun).
3. Document recipe for Parallel TLAB-on research:
   ```
   EC_PARALLELISM=4 GCRY_TLAB=1 \
     GCRY_PARALLEL_DORMANT=1 GCRY_EMPTY_CHUNK_RETAIN=33554432 \
     GCRY_TLAB_SKIP_FIND_BLOCK=1
   ```
4. Residual vs TLAB-off (~108k): still ~**½–⅗**; next is accept gap or hold
   shrinkage — not another blind `find_block` tweak.

## Non-goals

- Do not enable skip when `PARALLEL_RELEASE` / EC1 empty munmap.
- Do not remove `find_block` from the default TLAB hit path.
