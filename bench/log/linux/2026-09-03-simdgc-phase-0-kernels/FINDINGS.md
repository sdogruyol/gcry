# simdgc Phase 0 — SIMD kernels and CPU dispatch

Date: 2026-09-03 · host: WSL2, AMD Ryzen AI 9 HX 375 (Zen 5, 24 threads, 12 GB)
Crystal 1.21.0 [57cf7da50] · LLVM 20.1.8 · x86_64-unknown-linux-gnu
Branch `simdgc` · plan: `simd_plan/gcry-simdgc-plan.md` Phase 0

## What this phase claims

Nothing about gcry. Phase 0 adds `src/gcry/kernels.cr` and `src/gcry/cpu.cr` and
touches no collector code, so there is no throughput or RSS number to report and
none is claimed. What it establishes is whether the plan's central premise is
true on this toolchain: that **Crystal can ship vectorised bitmap kernels in a
shard**, without `--mattr`, without vector types, and without asking the user
anything.

Stated before measuring: the premise holds if (a) `@[TargetFeature]` clones
compile and coexist in one binary, (b) the IR shows real vector ops in the
clones, (c) every clone agrees with the scalar oracle, and (d) sweep clears
20 GB/s of bitmap on AVX2.

## (a) and (b) — the compiler does what the plan needs

`@[TargetFeature("+avx2,…")]` and `@[TargetFeature("+avx512f,…")]` clones of the
same source body compile and coexist, selected at run time. From
`crystal build --release --emit llvm-ir`:

| clone | vector ops in IR | popcount lowering |
|---|---|---|
| `sweep_words_scalar` | none | scalar `ctpop` — correct, x86-64 baseline has no `popcnt` |
| `sweep_words_avx2` | `<4 x i64>` ×44 | `llvm.ctpop.v4i64` ×4 |
| `sweep_words_avx512` | `<8 x i64>` ×82 | `llvm.ctpop.v8i64` ×8 → **`vpopcntq` ×9 in asm** |

`all_zero` and `range_any` also vectorise to `<4 x i64>` under AVX2. That last
one mattered: `range_any` had to be written as an OR-reduction group-skip rather
than the `movemask` compress-and-iterate `simdgc.c#gc_scan_range` uses, because
Crystal cannot express `movemask`. The restructured form vectorises.

`llvm.prefetch.p0` binds as a plain `fun` in a `lib` and emits `prefetcht0` for
both the read and write forms. The three `immarg` operands are literal constants
at the only two call sites, which is what makes that legal.

## (c) — equivalence

`spec/kernels_spec.cr`, 11 examples: ~6.7e7 bit decisions of `sweep_words` across
4096 random bitmaps at three densities (all-zero, all-ones, random), plus
`popcount_words`, `all_zero`, `range_any` against the scalar oracle, plus
half-open boundary cases and zero-length runs. Every tier agrees on both the
returned counts **and** both mutated bitmaps.

**The gate is `make kernels-broken`, and it was observed red before this was
worth anything.** `-Dgcry_kernels_broken` drops the last word from the vector
clones only; the fuzz went `10 examples, 4 failures` with genuine mismatches
(`Expected: {1008, 989} got: {987, 973}`), then green unbroken. The target
matches on `N examples, M failures` with M > 0 rather than on a non-zero exit,
because a compile error or a moved spec path also exits non-zero and would leave
the gate reporting a positive control that never ran. It also refuses outright on
a scalar-only host, where breaking the vector clones changes nothing.

## (d) — the floor

`make bench-kernels`, 12 passes, per-chunk call shape (64 words = one class-0
128 KiB chunk's bitmap), walking an arena so no call is loop-invariant. GB/s of
bitmap streamed:

| kernel | set | scalar | avx2 | avx512 |
|---|---|---:|---:|---:|
| `sweep_words` | L2 | 20.4 | **66.2** | 187.0 |
| `sweep_words` | DRAM | 18.8 | **26.7** | 27.1 |
| `popcount_words` | L2 | 21.4 | 80.9 | 224.6 |
| `popcount_words` | DRAM | 19.9 | 45.4 | 48.7 |
| `all_zero` | L2 | 159.4 | 291.5 | 275.1 |
| `all_zero` | DRAM | 46.5 | 49.1 | 51.6 |
| `range_any` (miss) | L2 | 44.1 | 205.1 | 248.8 |
| `range_any` (miss) | DRAM | 38.2 | 47.1 | 53.4 |

**Gate met: AVX2 sweep is 66.2 GB/s L2-resident and 26.7 GB/s at DRAM, against a
bar of 20.**

The shape is the more useful result. The tiers spread 3x at L2 and **converge at
DRAM** (26.7 vs 27.1, under 2%), which is `simdgc-perf-notes.md`'s finding
reproduced on different hardware: the kernel is bandwidth-bound on a real heap,
so the vector width stops mattering and AVX-512 is worth ~1.3x on sweep rather
than 2x. Two consequences for later phases: the AVX-512 tier should be justified
per kernel from the IR rather than assumed, and Phase 3's sweep win will come
from *not walking headers*, not from the vector width.

### The first cut of this benchmark measured nothing

Worth recording because it nearly shipped. The first version reported
`popcount_words` at 1804 GB/s — about 200 words per nanosecond, which is not a
measurement. Three causes, all of them the classic ones: the kernels were called
on the same pointers every iteration, so LICM hoisted them out of the timing
loop; the results were unused, so DCE removed what was left; and `sweep_words`
*consumes* its input (`occ = mark`, `mark = 0`), so the restore between
iterations was a `memcpy` of exactly the bytes being measured. The rewrite walks
an arena in per-chunk slices (different pointers per call, and the real call
shape), folds every result into an escaped `SINK` that is printed at the end, and
stops the clock across each reseed rather than subtracting an estimate. The
numbers above are from the rewritten version; the DRAM convergence reproducing a
published result on unrelated hardware is the main reason to believe them.

## Divergences from the plan document, decided here

- **`@simd_tier : UInt8` + `case`, not a `Proc` per kernel.** The plan's stated
  reason (allocation) is wrong — a non-capturing method-reference `Proc` is
  allocation-free. The real reasons: `size_classes.cr:2-4`'s house rule against
  runtime constant initializers before `Fiber` is up, and that a `case` on a
  `UInt8` is inspectable in the `--emit llvm-ir` gate while a `Proc` ivar is not.
- **`GCRY_SIMD` is read with `LibC.getenv`, not `ENV[]`.** `Heap#initialize` runs
  inside `GC.init` under `-Dgc_none`, before `Fiber` exists; `gc_override.cr:520`
  records that `ENV[]` allocates and can SEGV there. The override clamps down
  only — naming a tier the CPU lacks would be a SIGILL, not a fallback.
- **aarch64 gets no clones.** NEON is ARMv8-A baseline, so the scalar body *is*
  the NEON body and LLVM vectorises it unconditionally. The aarch64 IR gate looks
  for `<2 x i64>`. Not verified on hardware in this session — CI's
  `ubuntu-24.04-arm` and `macos-latest` runners are where that gets its first
  reading.

## Gates run

| Gate | Result |
|---|---|
| `crystal spec spec/kernels_spec.cr` | 11 examples, 0 failures |
| `make kernels-broken` | positive control **observed red** (4 failures), control green |
| `crystal tool format --check` | clean |
| `ci/knob-doc-check.sh` | ok — 148 knobs, `GCRY_SIMD` documented |
| IR / asm inspection | `<4 x i64>`, `<8 x i64>`, `vpopcntq`, `prefetcht0` |

## Next

Phase 1 introduces the per-chunk **mark** bitmap only — no `occ`, no allocator
change. The reason is `2026-08-01-ec4-alloc-bits` and `-ec4-used-count-v2`: both
rejects of accounting maintained on top of the existing allocator, and `occ`
maintained beside a cross-chunk freelist would be the same design. Phase 1's own
gate is that Kemal `/json` is **flat** — a regression there would mean the chunk
metadata growth alone costs, which is the v1 signal and grounds to stop.
