# Kemal tip med3 on i3-12100F after retain=0

**Date:** 2026-08-04 · Host: WSL2 **i3-12100F** (PERF headline host)  
**gcry tip** with Linux retain=0 defaults · Crystal 1.21.0  
**Method:** `FORCE_REBUILD=1 TRIALS=3 WRK_DURATION=30 GC=both bash bench/run_all.sh kemal`  
**Session:** `bench/log/linux/2026-08-04-045839/`

## Result (harness med/med)

| Path | % Boehm | RSS × |
|------|--------:|------:|
| `/` | **83.5%** | **0.75×** |
| `/json` | **79.5%** | **0.75×** |

gcstats `/json`: retain 0/0, `unmapped_bytes` ~7.0–7.6 GB/trial,
`pause_p50` ~0.56–0.63 ms.

## Same-trial `/json` ratios (Boehm was loud)

| Trial | Boehm rps | gcry rps | same-trial % |
|------:|----------:|---------:|-------------:|
| 1 | 43501 | 35667 | **82.0%** |
| 2 | 40852 | 34530 | **84.5%** |
| 3 | 43457 | 33110 | **76.2%** |

Harness median/median (**79.5%**) understates the quieter pairing; band
~**76–84%**. Absolute gcry med ~34.5k — not a thr cliff vs tip abs on 9950X
(~35k @ 85%).

## vs prior i3 / 9950X

| Session | Host | `/json` % | RSS × |
|---------|------|----------:|------:|
| v0.16 headline (`2026-08-01-093130/`) | i3 | **~87%** | **~0.80×** |
| 0.18 Phase 0 (`120500/`) | i3 | **87.9%** | **0.81×** |
| retain0 reconfirm (`042404/`) | 9950X | **85.0%** | **0.78×** |
| **this** | **i3** | **~80%** (med/med) / ~82% same-trial | **0.75×** |

Soft ≥90%@≤0.85× still **MISS**. RSS still Boehm-under. No retain=0 cliff
vs shipping defaults — thr % softer than quiet v0.16/0.18 i3 cuts largely
from louder Boehm this session. **Headline stays v0.16** in [PERF.md](../../../docs/PERF.md).
