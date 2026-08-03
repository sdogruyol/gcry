# Kemal smoke after Linux retain=0 defaults

**Date:** 2026-08-03 · Session harness: `2026-08-03-191321/` (copied summary here).  
**Method:** `FORCE_REBUILD=1 TRIALS=1 WRK_DURATION=20 GC=both bash bench/run_all.sh kemal`

## Result

| Path | thr % Boehm | RSS × |
|------|------------:|------:|
| `/` | **86.5%** | **0.73×** |
| `/json` | **84.3%** | **0.76×** |

## Read

No thr/RSS cliff vs PERF headline (~87% `/json` @ ~0.80×). Retain=0 defaults
look fine on toy Kemal; acik remains the fat-app gate.
