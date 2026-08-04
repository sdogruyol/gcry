# Kemal tip med3 after Linux retain=0 defaults

**Date:** 2026-08-04 · Host: WSL2 Ryzen 9 9950X · Crystal 1.21.0  
**gcry:** `stack-maps` tip (retain=0 Linux defaults, finalizer registry fix)  
**Method:** `FORCE_REBUILD=1 TRIALS=3 WRK_DURATION=30 GC=both bash bench/run_all.sh kemal`  
**Session:** `bench/log/linux/2026-08-04-042404/`

## Result

| Path | % Boehm | RSS × |
|------|--------:|------:|
| `/` | **83.3%** | **0.76×** |
| `/json` | **85.0%** | **0.78×** |

gcstats `/json` (med-ish): `empty_chunk_retain=0`, `large_cache_retain=0`,
`unmapped_bytes` ~**7.5 GB**/trial, `pause_p50` ~**0.57 ms**, ~195 collections.

## vs prior 9950X hunt

| Session | `/json` % | RSS × | Note |
|---------|----------:|------:|------|
| `072122/` / `072954/` | 80–83% | 0.76× | pre-retain0-default hunt |
| retain0 smoke (`…/kemal-release0-smoke/`) | ~84% | 0.76× | 1 trial |
| **this** | **85.0%** | **0.78×** | med3 |

No cliff from shipping retain=0. Soft ≥90%@≤0.85× and hard ≥95%@≤1.0× still
**MISS**. Flush/munmap tax unchanged (~GB-scale unmap).

## Gate

| Gate | Result |
|------|--------|
| ≥90% @ ≤0.85× | **MISS** (~85% @ 0.78×) |
| ≥95% @ ≤1.0× | **MISS** |

Parent campaign: [2026-08-02-018-FINDINGS.md](../2026-08-02-018-FINDINGS.md).
