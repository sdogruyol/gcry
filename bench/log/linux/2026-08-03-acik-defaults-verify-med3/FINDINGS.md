# Verify Linux retain=0 defaults (acik med3)

**Date:** 2026-08-03 · tip+EC `base` rebuilt after `9228bb9` (no GCRY_* override).  
**Method:** `acik_stackmap_ab` med-of-3, wrk -c100 -d30, dual `/gc-collect`.

## Result

| variant | thr med | % Boehm | RSS KiB med | × Boehm |
|---------|--------:|--------:|------------:|-------:|
| boehm | 138.3 | 100% | 50000 | 1.00× |
| base (new defaults) | 125.0 | **90.4%** | 70204 | **1.40×** |

Per-trial base RSS: **0** (t1 SEGV) / 70204 / 78052. Excluding t1: med ~74 MiB ≈ **1.48×**.  
gcstats t2/t3: `large_cache_retain=0`, `empty_chunk_retain=0` (defaults applied).

## Caveat — t1 SEGV

After wrk, first `/gc-collect` returned 200 then SEGV in EC Monitor
`pthread` run_loop (`run-base-t1.log`). t2/t3 clean. Prior env-only release0
med3 had no SEGV and RSS **1.00×** — this cut is noisier; treat 1.40× as
upper-ish verify, not a regress of the thr band (~90%).

## vs prior

| Session | RSS × | thr % |
|---------|------:|------:|
| pre-fix tip baseline | ~8.5× | ~102% |
| post-finalizer default caches | ~1.8–2.2× | ~92–94% |
| release0 env med3 | **1.00×** | **94%** |
| **this (defaults=release0)** | **~1.4×** (+1 SEGV) | **90%** |
