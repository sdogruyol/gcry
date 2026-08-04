# denser Crystal emit → exclusivef re-check (2026-08-03)

## Emit change (tip Crystal `gcry-stackmap-probe`)

- Stackmaps at **External** calls (was skipped).
- Include **call_args** pointer lives.
- **Pre-call** maps when `CRYSTAL_STACKMAP_PER_FUN=0` (or `CRYSTAL_STACKMAP_BEFORE=1`).

Bin: `gcry/.tmp/acik-bin/acikturkiye-exclusive` (`PER_FUN=0`, tip crystal).

## Result (15s wrk, live-attr)

| label | max_atomic MiB | parked→atomic | heap→atomic | live | records | hits | fp_fill | rps | status |
|-------|----------------|---------------|-------------|------|---------|------|---------|-----|--------|
| exclusive (`=2`, full parked scan) | 74.2 | 5.2 | 66.3 | 95.4 | **305944** | 53419 | 0 | 77 | ok |
| exclusivef + FP-fill | 87.2 | 5.7 | 78.9 | 99.9 | 305944 | 67923 | **0.67 MiB** | 103 | ok |
| exclusivef + `DISABLE_FIBER_FP_FILL=1` | — | — | — | — | — | — | — | 3.8 | **SEGV** |

Prior exclusive bins had ~139k records; denser emit ≈ **2.2×** map sites.

## Verdict

1. Emit density landed (record count).
2. Pure exclusivef still UAF — FP-fill remains required for survival.
3. FP-fill volume unchanged (~0.6–0.7 MiB); RSS not improved vs exclusive full-scan.
4. Product path stays `GCRY_PRECISE_STACK=2` **without** `PRECISE_FIBERS`.

## Next

- Find which parked frames still miss lives (IO park / makecontext) beyond External+pre-call.
- Or accept FP-fill as exclusivef floor and chase RSS elsewhere (atomic Builder retention).
