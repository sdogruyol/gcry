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

1. **Tip+EC base already ~15× RSS** on this host — far above the Linux tip
   headline ~3.43× (i3 / system Crystal). Stack maps are not the first-order
   RSS regressor here; tip/EC cut needs its own baseline before map A/B.
2. **Stackmap emit thr cost** is large on this fat binary (~67%→33% Boehm).
3. **No RSS win from hybrid** (expected while additive + zero marks).
4. Next: (a) why tip base RSS ≫ 3.43× on 9950X; (b) wire hybrid hits
   (mutator near-PC or ensure STW greqs); (c) exclusive trial once (a) is sane.

Do not promote stack maps or cut a version from this smoke.
