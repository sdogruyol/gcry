# `make nursery-bitmap-marks` was testing a no-op minor

**Date:** 2026-09-20 · host: Linux 7.0.0-31-generic x86_64 · Crystal 1.21.0
Tree `3751d56` · `python3 bench/gate_arm_census.py`

`make nursery-bitmap-marks` built `bench/nursery_bitmap_marks.cr` without
`-Dgcry_block_headers`. `Heap#nursery_enabled=` is a no-op on that layout
(Phase 7.3), `bitmap_marks=` is the same no-op, and `minor_collect`
returns immediately. The child survived as an uncollected object. Both
arms would have stayed green through the pre-fix clear that gated on the
global `@bitmap_marks` flag — the 2026-09 defect where a nursery block
read marked forever and anything reachable only through it was reclaimed
while live.

It was not in CI. The recipe existed and could not fail.

## What changed

Green builds `-Dgcry_block_headers`, requires the nursery actually on,
and requires a per-chunk clear on three representations (header marks,
bitmap marks, bitmap allocator). `--disabled` is
`GCRY_NURSERY_MARKS_GLOBAL=1`: the global flag, so bitmap arms must lose
a child reachable only through a marked nursery parent. The header-marks
arm is the control and must keep it — the break is that flag, not
"every minor loses the child". Dropping `-Dgcry_block_headers` or the
knob reddens the gate (exit 64) rather than hiding it.

## Measured

| arm | result | notes |
|---|---|---|
| green (`-Dgcry_block_headers`) | exit 0 | header/bitmap/allocator: live, reissued=0, canary intact |
| `--disabled` | exit 0 | header live; bitmap + allocator: live=false, reissued=1, canary gone |
| headerless (compile default) | exit **64** | nursery never on |
| `--disabled` without the knob | exit **64** | guard, 0.0 s |
| headerless `--disabled` + knob | exit **64** | nursery never on |

The bitmap `--disabled` arm handed the child's address out again once in
400 attempts. That is the original report: the parent stayed marked, the
minor never scanned it, the child was swept and reissued.

## Census

```
harness-driven gates:              99
red direction constructed per run: 66
red direction established by hand: 33
prose claims of a hand break:      19 (nothing re-checks these)
```

**99 / 65 / 34 → 99 / 66 / 33.** `nursery-bitmap-marks` moved: recipe 1,
harness 0. The recipe now has `-Dgcry_block_headers` and `--disabled`.

Still a real gap, in CI: `nested-spawn-uaf` (the original repro;
`dead-stack-root` is the gate), `occupied-release` (recipe prefixes
both arms with `-`), and `nursery_tlab_smoke` (CI still builds it
headerless).
