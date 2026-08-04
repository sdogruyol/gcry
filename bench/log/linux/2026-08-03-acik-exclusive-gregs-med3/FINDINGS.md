# Parked sysv gregs + exclusive acik med-of-3 (2026-08-03)

Host: WSL2 / Ryzen 9 9950X. `wrk -c100 -d30`, med-of-3, non2xx=0.

## Runtime fix

Parked fiber precise walk was wrong on two counts:

1. **RSP** passed as `stack_top` (spill block) instead of caller SP at return
   (`stack_top + 64` = past 7 spills + ret).
2. **gregs=null** — Register GP lives (and many LLVM encodings) unresolved.

Now: `StackMaps.fill_parked_sysv_gregs` / `each_root_parked_sysv` synthesize
glibc-order gregs from x86_64-sysv spill slots + RIP/RSP@ret.

Harness: preserve `GCRY_PRECISE_FIBER_LEAF` across `GCRY_*` scrub; leaf clamp
raised to 16 MiB (was silently rejecting >1 MiB).

## Med-of-3 (exclusive = full parked word-scan + precise)

| variant | thr med | thr % Boehm | RSS KiB med | × Boehm |
|---------|--------:|------------:|------------:|--------:|
| boehm | 263 | 100% | 42784 | 1.00× |
| base (tip+EC) | 263 | 100% | 367912 | **8.60×** |
| exclusive | 246 | **93%** | 333836 | **7.80×** |

Trials RSS KiB: base 367960 / 367912 / 306592; exclusive 333836 / 288808 / 339276.

Modest RSS win vs base (~9% relative) at thr hold. Still far from ~3.43× tip
headline / ~1.2× hypothesis.

## exclusivef (`GCRY_PRECISE_FIBERS=1`, LEAF=0)

- One early 15s smoke: **PASS** (240 rps, 4.25×, marked=6640)
- Later 15s ×3: **all SEGV** — flaky, not cut-ready
- LEAF=8 MiB (≈ full parked scan): survives but thr cliff (~57 rps) — walker cost

Do not promote exclusivef. Keep `=2` with parked word-scan as the stable path.

## Next

- Stabilize exclusivef (makecontext vs swapcontext layout; walker cost)
- Or accept ~7.8× exclusive band and hunt non-stack retention
