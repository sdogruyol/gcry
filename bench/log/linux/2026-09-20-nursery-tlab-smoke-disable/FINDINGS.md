# `make nursery-tlab-smoke` was testing a no-op minor

**Date:** 2026-09-20 · host: Linux 7.0.0-31-generic x86_64 · Crystal 1.21.0
Tree `81e250e` · `python3 bench/gate_arm_census.py`

CI built `bench/nursery_tlab_smoke.cr` without `-Dgcry_block_headers`.
`Heap#nursery_enabled=` is a no-op on that layout (Phase 7.3),
`tlab_enabled=` is refused because the bitmap allocator is forced
(TLAB is freelist-shaped), and `minor_collect` returns immediately.
Twenty rooted objects surviving a no-op is not a gate. TLAB also
cannot be turned on after the process heap has mapped bitmap chunks,
so `GCRY_BITMAP_ALLOC=0` has to be set at start.

The defect the smoke exists for: FREE-claim during minor cleared
FREE on an *old* TLAB freelist node before the minor/old filter,
leaving USED-unmarked for scrub to drop. Nursery nodes still claim.
A major does not clear NURSERY (`BlockHeader.promote` runs on a
surviving minor); the plant has to survive a minor, then be freed.

## What changed

Green builds `-Dgcry_block_headers`, runs under `GCRY_BITMAP_ALLOC=0`,
requires nursery and TLAB actually on, TLAB hits, rooted objects
alive across 10 minors, an old FREE node still FREE after a minor,
and an unrooted nursery object swept (`scan_stack: false`).
`--disabled` is `GCRY_TLAB_MINOR_FREE_OLD=1`: the pre-fix claim, so
the old FREE node must become USED. Dropping `-Dgcry_block_headers`,
`GCRY_BITMAP_ALLOC=0`, or the knob reddens the gate (exit 64).
Dropping the assignment in `mark_impl` reddens `--disabled` (exit 1).

## Measured

| arm | result | notes |
|---|---|---|
| green (`-Dgcry_block_headers` + `GCRY_BITMAP_ALLOC=0`) | exit 0 | 5/5; still_free=true, tlab_hits=42–43, minors=12 |
| `--disabled` | exit 0 | 5/5; still_free=false, tlab_hits=42–43 |
| `--disabled` with the assignment dropped | exit **1** | still_free=true, FAIL |
| `--disabled` without the knob | exit **64** | guard |
| no `GCRY_BITMAP_ALLOC=0` | exit **64** | TLAB refused |
| headerless (compile default) | exit **64** | bitmap allocator forced, TLAB refused |

## Census

```
harness-driven gates:              100
red direction constructed per run: 67
red direction established by hand: 33
prose claims of a hand break:      19 (nothing re-checks these)
```

**99 / 66 / 33 → 100 / 67 / 33.** `nursery-tlab-smoke` is a new Makefile
gate (it was a CI inline build, not a census row). Recipe 1, harness 0.

Still a real gap in CI: `nested-spawn-uaf` (the original repro;
`dead-stack-root` is the gate), `occupied-release` (recipe prefixes
both arms with `-`), and `stw_mt_property_test --tlab --nursery`
(CI still builds it headerless, so both flags are no-ops and the
step still passes).
