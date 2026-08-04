# exclusivef + FP-frame fill (2026-08-03)

## Change

`GCRY_PRECISE_FIBERS=1` + `LEAF=0` no longer pure maps. After precise parked
walk, word-scan each FP-chain frame body `[rsp,fp)` with caps:

- max **64 KiB**/frame, **256 KiB**/fiber
- reject leaf if `(rbp-rsp) > 64 KiB` (stale RBP → full-stack trap)

Escape: `GCRY_DISABLE_FIBER_FP_FILL=1` (old pure-maps / UAF path).

Uncapped first try: thr ~3 rps, collect hang (one “frame” ≈ whole stack).

## Result

| Check | Outcome |
|-------|---------|
| `make stackmap-smoke` (probe Crystal) | PASS |
| acik exclusivef 15s wrk | **SURVIVED** (no SEGV) |
| wrk | ~123 req/s (timeouts; soft) |
| `parked_fp_fill_frames` | 2841 |
| `parked_fp_fill_bytes` | **0.57 MiB** |
| max_atomic / live | ~88 / ~98 MiB (≈ exclusive full-scan band) |

## Verdict

1. **Correctness:** exclusivef no longer instant UAF on acik with FP-fill caps.
2. **RSS:** not a win yet — frame fill still feeds parked false roots into the
   atomic closure (~6.8 MiB parked→atomic seed, ~79 MiB heap→atomic).
3. Stable product path remains `PRECISE_STACK=2` without `PRECISE_FIBERS` until
   maps densify enough to shrink/disable FP-fill.

## Next

- Denser parked call-site lives (Crystal) so FP-fill can shrink or go opt-in.
- Optional: med-of-3 exclusive vs exclusivef thr/RSS once thr stable.
MD