# acikturkiye × stack maps — smoke (2026-08-03)

Host: WSL2 / Ryzen 9 9950X. Probe Crystal `gcry-stackmap-probe` +
`-Dpreview_mt -Dexecution_context`. `wrk -c100 -d15` /api/v1/, 1 trial.
Script: `bench/acik_stackmap_ab.sh`.

## Build unblocks

- Fat `--release` + `CRYSTAL_EMIT_STACKMAP=1` crashed LLVM 18
  (`LowerStatepoint` via `visitInvoke`) until stackmap calls were marked
  **nounwind**.
- Skip emit after Crystal `invoke` sites; cap `CRYSTAL_STACKMAP_PER_FUN=2`.

## Smoke numbers (1×15s)

| variant | thr | thr % Boehm | post-GC RSS | × Boehm |
|---------|----:|------------:|------------:|--------:|
| boehm (system 1.21.0) | 415 | 100% | 45 MiB | 1.00× |
| base (tip+EC, no maps) | 276 | 67% | 700 MiB | **15.6×** |
| hybrid (maps + `GCRY_PRECISE_STACK=1`) | 136 | 33% | 651 MiB | **14.5×** |

### Hybrid gc-stats

- `stack_maps_loaded=true`, **86135** records
- `precise_stack_roots_marked=0`, `lookups=0`, `hits=0`

Hybrid leaf path never consulted the map (likely STW `ngregs` empty / no
other-thread near-lookup). Mutator FP walk is exclusive-only. So this smoke
does **not** exercise precise marking on acik.

## Takeaways

1. **~~Tip+EC base ~15×~~ INVALID** — wrk was **100% Non-2xx** (missing
   `submissions`). Superseded by
   `../2026-08-03-acik-tip-baseline2-med3/` (~**8.5×**, tip≈sys, non2xx=0).
2. **Stackmap emit thr cost** on this smoke is unreliable (exception path).
3. **No RSS win from hybrid** (expected while additive + zero marks) — still
   the open walker-hit issue.
4. Next: wire hybrid hits; exclusive A/B vs valid ~8.5× baseline.

Do not promote stack maps or cut a version from this smoke.
