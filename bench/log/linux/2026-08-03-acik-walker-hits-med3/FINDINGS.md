# Hybrid walker hits on acik (2026-08-03)

Host: WSL2 / Ryzen 9 9950X. Demo DB seeded (non2xx=0).
`wrk -c100 -d30`, med-of-3. Script: `bench/acik_stackmap_ab.sh`.
Smoke (1×15s + exclusive): `../2026-08-03-acik-walker-hits/`.

## Fix

Hybrid previously skipped the mutator FP walk (`return unless exclusive`), so
EC1 acik never called `find_index_near` (no other-thread gregs). Now:

- Hybrid: capped mutator FP walk (`HYBRID_MAX_FP_FRAMES=32`) + conservative
- Exclusive: full walk, no word scan (unchanged; still research)

Cap must clear GC/stdlib frames before Crystal map PCs appear (4 was too low).

## Med-of-3 (non2xx=0)

| variant | thr med | thr % Boehm | RSS KiB med | × Boehm | marked med |
|---------|--------:|------------:|------------:|--------:|-----------:|
| boehm | 249 | 100% | 43360 | 1.00× | 0 |
| base (tip+EC, no maps) | 263 | 106% | 389516 | **8.98×** | 0 |
| hybrid (maps + `=1`) | 264 | 106% | 394844 | **9.11×** | 2 |

Smoke hybrid gc-stats (15s): `lookups=1346`, `hits=974`, `records=86135`,
`marked=2` (per last collect).

## Verdict

1. **Walker consulted** — hybrid lookups/hits ≫ 0; smoke `marked>0`.
2. **No RSS win from hybrid** — additive path cannot drop conservative false
   roots; med RSS ≈ base (noise). Expected.
3. **Exclusive SEGVs** on acik (signal 11 @ ~15s / write storm) — maps still
   incomplete for dropping the word scan. Keep `=2` research-only.
4. Gate (~close 8.5–9× → ~1.2×) still needs denser/correct lives + exclusive
   (or another precise-only path) that does not UAF.

## Next

- Densify / correct stackmap lives (parked fibers, Proc/union, invoke sites)
- Exclusive soft-soak / acik once maps cover enough roots
- Do not cut a version from hybrid alone
