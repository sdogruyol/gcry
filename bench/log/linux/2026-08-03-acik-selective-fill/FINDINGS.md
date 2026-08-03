# Selective (miss-only) FP-fill (2026-08-03)

## Change

`each_parked_fp_frame_range` can skip frames with a non-empty stackmap near
the frame PC (leaf RIP / ret@fp+8). Counters:

- `parked_fp_fill_*` — actually word-scanned
- `parked_fp_fill_skipped_*` — map-hit skips

## Result (acik 12–15s)

| mode | status | fill | skip | max_atomic |
|------|--------|------|------|------------|
| exclusivef **default** (fill-all) | **ok** ~114 rps | **0.67 MiB** | 0 | ~78 MiB |
| `GCRY_FIBER_FP_FILL_MISS_ONLY=1` | **SEGV** | — | — | — |

First try had miss-only as default → same SEGV; flipped to opt-in.

## Verdict

1. **Map hit ≠ complete lives** on acik — skipping fill on hits UAFs.
2. Miss-only stays research (`GCRY_FIBER_FP_FILL_MISS_ONLY=1`); default remains
   fill-all (~0.6–0.7 MiB).
3. Exclusivef still no RSS win vs `PRECISE_STACK=2` full parked scan.
4. Product path unchanged: `=2` without `PRECISE_FIBERS`.

## Next

- Emit denser / more accurate lives so miss-only can become default, **or**
- Leave exclusivef + fill-all as research floor; chase atomic Builder RSS on `=2`.
