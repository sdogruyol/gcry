# Kernel backends — hand assembly vs LLVM's vectoriser (post-#36)

Date: 2026-09-07 · host: AMD Ryzen AI 9 465 (Zen 5, 20 threads), Linux 7.2.2
Crystal 1.21.0 [4da7e07] · LLVM 20 · x86_64-unknown-linux-gnu
Branches: `v0.24.0` (57f3cae) · `master` at the #36 merge (0197b54) ·
`master` after the follow-ups (cfc6afe, "head")

## Question

#36 replaced the `@[TargetFeature]`-cloned Crystal loop bodies with hand-written
AVX2 / AVX-512 / NEON / SVE assembly and reported +39.7% AVX2 sweep and +37.8%
AVX2 popcount on its author's host. Does that hold on a Zen 5, and which kernels
should stay in assembly?

Stated before measuring: a kernel keeps its assembly only if it is at least at
parity with the vectorised body on this (AMD) part, given the author's win on
theirs. Anything slower here goes back to the compiler.

## Method

`make bench-kernels` binary from each tree, `--passes=30`, six rounds, the three
binaries rotated each round so no binary always runs hottest. Reported number
is the **max** across the six runs — the least frequency-scaling-noisy statistic
on a laptop part. Raw output: `v0.24.0.log`, `pr36.log`, `head.log`.

Per-chunk call shape (64 words = one class-0 128 KiB chunk's bitmap), walking an
arena so no call is loop-invariant; see `bench/micro/kernels.cr` for why the
first cut of that file measured nothing.

## Result — L2-resident, GB/s of bitmap

Chunk bitmaps are ~1 KiB and live in L1/L2, so this is the column that matters.

| kernel | tier | v0.24.0 | #36 merge | head | head vs v0.24.0 | head vs #36 |
|---|---|---:|---:|---:|---:|---:|
| `sweep_words` | avx2 | 50.3 | 45.9 | **48.2** | -4% | +5% |
| `popcount_words` | avx2 | 61.3 | 46.2 | **59.3** | -3% | +28% |
| `all_zero` | avx2 | 202.5 | 97.6 | **194.1** | -4% | +99% |
| `range_any` (miss) | avx2 | 140.0 | 79.1 | **134.8** | -4% | +70% |
| `sweep_words` | avx512 | 139.9 | 110.7 | **129.3** | -8% | +17% |
| `popcount_words` | avx512 | 170.6 | 129.8 | **164.2** | -4% | +27% |
| `all_zero` | avx512 | 188.0 | 136.2 | **185.0** | -2% | +36% |
| `range_any` (miss) | avx512 | 175.7 | 124.1 | **179.0** | +2% | +44% |

The #36 assembly, against v0.24.0's vectorised bodies: AVX2 sweep -9%, popcount
-25%, all_zero -52%, range_any -44%; AVX-512 sweep -21%, popcount -24%,
all_zero -28%, range_any -29%.

`head` is back at parity with v0.24.0 (-8…+2%, inside this session's run-to-run
spread — the *unchanged* scalar kernels moved -20…+5% between the three
binaries, which bounds the noise).

## Why the assembly lost

Read from `--emit asm` of v0.24.0: LLVM already lowers `ctpop <4 x i64>` under
AVX2 to the VPSHUFB nibble lookup + VPSADBW (34 occurrences in the popcount
clone, i.e. unrolled), and `ctpop <8 x i64>` under `+avx512vpopcntdq` straight
to VPOPCNTQ. The OR-reductions are unrolled with four accumulators. The #36
loops used one accumulator, no unroll, and rematerialised the nibble mask and
lookup table (`movabsq` + `vmovq` + `vpbroadcastq` ×2) on every call — on a
16-iteration 64-word bitmap the setup is a visible fraction of the work. The
algorithm was the same as the compiler's; the schedule was worse.

## Decision

- **AVX2 `sweep_words` stays in assembly.** Parity here (-4% vs v0.24.0, +5% vs
  #36, both inside noise), a claimed +40% on the author's Intel part.
- **Everything else on x86 is the vectorised body** (`def_autovec_*` in
  `kernels.cr`), including the AVX-512 sweep, for which #36 reported no delta
  and which measured -21% here.
- **NEON is the vectorised body** — the code that shipped through 0.24.0. The
  #36 NEON loop reduced through a GPR every 128 bits (`uaddlv` + `umov` + `add`
  per two words) and was never A/B'd on native ARM; no ARM host was available
  here either. **[INFERENCE]** that it would lose to LLVM's `uaddlp` chain.
  Cross-compiled IR confirms the body vectorises (`llvm.ctpop.v2i64` ×19).
- **SVE keeps its assembly.** LLVM does not vectorise for SVE from a generic
  AArch64 build, so it is the only way to run SVE at all. SVE2 backend dropped:
  it was a byte-identical copy of SVE under a different feature string.
- Rule going forward, written into `kernels.cr`: hand assembly earns its place
  only with an A/B on both an Intel and an AMD part.

## DRAM column — recorded, not decision-grade

| kernel | tier | v0.24.0 | #36 merge | head |
|---|---|---:|---:|---:|
| `sweep_words` | avx2 | 21.8 | 28.9 | 26.7 |
| `popcount_words` | avx2 | 28.9 | 39.7 | 38.6 |
| `sweep_words` | avx512 | 21.8 | 26.2 | 29.8 |
| `popcount_words` | avx512 | 33.7 | 35.6 | 44.2 |

The identical scalar kernels varied 12.2 → 15.6 → 11.7 GB/s (sweep) and
14.8 → 18.2 → 12.8 (popcount) across the three binaries at DRAM, i.e. ±30% on
unchanged code. The 2026-09-03 finding stands — the tiers converge at DRAM
because the kernel is bandwidth-bound there — but this session cannot rank
the backends from that column.

## Gates run

- `crystal spec --release spec/kernels_spec.cr` — 13 examples, 0 failures; also
  under `GCRY_SIMD=avx2`
- `make kernels-broken` — observed red (4 failures), then green
- `crystal spec` — 290 examples, 0 failures
- `make chunk-search-race` — 4/4; `make large-cache-race` — locked 0/5,
  unsafe control 5/5
- IR gates: x86 `vpandn`, `vpshufb` (AVX2 sweep asm) and `llvm.ctpop.v8i64`
  (AVX-512 vectorised); aarch64 `llvm.ctpop.v2i64`, `cnt z`, `whilelo`
