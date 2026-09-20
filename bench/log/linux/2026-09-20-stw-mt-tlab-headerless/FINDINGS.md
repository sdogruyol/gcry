# `make stw-mt-property-test-short` was testing a no-op TLAB

**Date:** 2026-09-20 · host: Linux 7.0.0-31-generic x86_64 · Crystal 1.21.0
Tree `94a706b` · `python3 bench/gate_arm_census.py`

CI built `bench/stw_mt_property_test.cr` `--tlab` and `--tlab --nursery`
without `-Dgcry_block_headers`. `Heap#nursery_enabled=` is a no-op on
that layout (Phase 7.3), `tlab_enabled=` is refused because the bitmap
allocator is forced (TLAB is freelist-shaped), and `minor_collect`
returns immediately. The harness printed `tlab_enabled=false
nursery_enabled=false` and still exited 0. TLAB also cannot be turned
on after the process heap has mapped bitmap chunks, so
`GCRY_BITMAP_ALLOC=0` has to be set at start.

The defect the property test exists for: process-STW × TLAB freelist
UAF (mid-`tlab_alloc_small` STW leaving FREE nodes only on mutator
stacks). That class cannot fire if TLAB never enables. The TLAB+nursery
arm also had two unattributed CI crashes (2026-08-17 x86_64,
2026-08-22 Darwin) whose absence after the headerless default is not
evidence.

## What changed

Green `--tlab` / `--tlab --nursery` builds `-Dgcry_block_headers`,
runs under `GCRY_BITMAP_ALLOC=0`, requires TLAB (and nursery) actually
on, and requires TLAB hits/refills. `--disabled` is the headerless
binary: those flags must not enable. Dropping `-Dgcry_block_headers`
or `GCRY_BITMAP_ALLOC=0` on a green arm: exit 64. Pointing
`--disabled` at the green config: TLAB on, FAIL.

## Measured

| arm | result | notes |
|---|---|---|
| headerless default (no flags, 2 workers × 2 iters) | exit 0 | tlab_hits=0 |
| headerless `--tlab --nursery --disabled` | exit 0 | neither enabled |
| headerless `--tlab` | exit **64** | guard |
| headerless `--nursery` | exit **64** | guard |
| headers, bitmap default, `--tlab` | exit **64** | TLAB refused |
| headers + `GCRY_BITMAP_ALLOC=0` `--tlab --disabled` | exit **1** | TLAB on |
| `--disabled` without flags | exit **64** | guard |
| green `--tlab` CI params (50 × 2,4, poison/census/audit/watchdog) | exit 0 | tlab_hits=1302 refills=469 |
| green `--tlab --nursery` CI params (same) | exit 0 | tlab_hits=1302 refills=211, nursery_enabled=true |

## Census

```
harness-driven gates:              100
red direction constructed per run: 69
red direction established by hand: 31
prose claims of a hand break:      19 (nothing re-checks these)
```

**100 / 67 / 33 → 100 / 69 / 31.** `stw-mt-property-test` and
`stw-mt-property-test-short` both gained `--disabled` on the
headerless binary. Recipe 1, harness 0.

Still a real gap in CI: `nested-spawn-uaf` (the original repro;
`dead-stack-root` is the gate), `occupied-release` (recipe prefixes
both arms with `-`).
