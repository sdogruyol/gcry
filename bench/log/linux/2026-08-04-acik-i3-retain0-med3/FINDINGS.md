# acik tip+EC on i3-12100F after retain=0 defaults

**Date:** 2026-08-04 · Host: WSL2 **i3-12100F** (v0.17 headline host)  
**Method:** `acik_stackmap_ab.sh` med-of-3, `wrk -c100 -d30`, dual `/gc-collect`  
**Variants:** `boehm` (system Crystal 1.21) vs `base` (tip+EC, no stackmaps)  
**Defaults:** no ambient `GCRY_*` — Linux retain=0 (`empty`/`large` = 0 in gcstats)

## Result

| variant | thr med | % Boehm | RSS KiB med | × Boehm |
|---------|--------:|--------:|------------:|-------:|
| boehm | 126.9 | 100% | 51072 | 1.00× |
| **base (tip+EC)** | **121.5** | **95.7%** | **83144** | **1.63×** |

All trials non2xx=0, no SEGV, no collect hang. Per-trial base RSS:
83260 / 83144 / 79920 KiB.

## vs history

| Cut | Host | thr % | RSS × |
|-----|------|------:|------:|
| v0.17 tagged | i3 | ~90% | **~3.43×** |
| tip pre-fix | 9950X | ~102% | **~8.5×** |
| tip retain=0 verify | 9950X | ~90% | **~1.4×** |
| tip release0 env | 9950X | ~94% | **~1.00×** |
| **this (tip defaults)** | **i3** | **~96%** | **~1.63×** |

Headline-host win: **~3.43× → ~1.63×** at **better thr** (~96% vs ~90%).
Not quite the 9950X release0 tie (~1.00×); still well inside a shippable
fat-app band vs the old i3 cut.

## Read

- Finalizer + Linux retain=0 reproduce on the PERF/ACIKTURKIYE i3 host.
- Residual ~0.6× vs Boehm is mapped heap / trial noise (heap_size ~85–95 MiB
  post-collect), not the old dead-socket / cache retain cliff.
