# NEON and SVE backends on a native ARM host — hand assembly vs LLVM

Date: 2026-09-08 · host: GitHub `ubuntu-24.04-arm`, Neoverse-N2 (SVE, SVE2)
Crystal 1.21.0 · aarch64-unknown-linux-gnu · run 34231263527 on a throwaway
workflow branch (`bench/kernels-arm`, deleted) · raw output: `run.log`

## Question

`2026-09-07-kernel-backend-ab` returned the NEON backend to LLVM's vectorised
bodies on the inference that #36's asm — a `uaddlv` + `umov` + `add` reduction
every 128 bits — would lose to the compiler's `uaddlp` chain, and kept the SVE
asm because the compiler cannot emit SVE from a generic build. Neither had a
native ARM reading. Two binaries, six rotated runs each, `--passes=30`, max:

- `asm`: tree `0197b54` (the #36 merge: NEON asm, SVE asm, SVE2 asm)
- `head`: `cdd1945` (NEON vectorised, SVE asm, no SVE2)

The SVE asm is byte-identical in both binaries, so its rows bound the noise.

## Result — L2, GB/s

| kernel | scalar | NEON asm (#36) | NEON vectorised | SVE asm | SVE2 asm |
|---|---:|---:|---:|---:|---:|
| `sweep_words` | 20.4 | 19.7 | **20.5** | **26.0** | 26.1 |
| `popcount_words` | 23.6 | **26.6** | 23.5 | **28.4** | 28.5 |
| `all_zero` | 65.1 | 30.4 | **65.2** | **256.8** | 245.0 |
| `range_any` (miss) | 45.2 | 27.3 | **45.3** | 21.9 | 21.8 |

SVE rows agree across the two binaries within ±2.4% (DRAM) and ±0.7% (L2);
that is the noise floor.

## What it says

1. **The NEON inference was right for the reductions and wrong for popcount.**
   The asm's `all_zero` and `range_any` are at 47% and 60% of the vectorised
   body — the per-vector GPR round trip — and its sweep is at parity. Its
   popcount is 13% ahead (26.6 vs 23.5): the `cnt` + `uaddlv` pair beats
   whatever LLVM schedules for `ctpop <2 x i64>` here. One kernel, one
   microarchitecture; it comes back when an Apple Silicon reading agrees.
2. **`range_any` under SVE is a regression** — 21.9 GB/s against 45.3 for the
   NEON body on the same host. The predicated loop exits through
   `cntp` + `cbnz` on every vector, and that serialises it. The SVE backend
   now stamps the vectorised NEON body for this kernel and keeps its asm for
   the other three, where it is 27% (sweep), 21% (popcount) and 3.9×
   (`all_zero`) ahead of NEON.
3. **SVE2 is SVE.** Every SVE2 row is inside noise of the SVE row, which is
   what the 0.24.1 removal of the SVE2 backend assumed.
4. The NEON vectorised rows equal the scalar rows to three digits: on
   AArch64 the "scalar" body *is* NEON code, as `kernels.cr` said in 0.23.

## Decision

- NEON backend stays vectorised.
- SVE backend: `range_any?` → `def_autovec_range_any("+neon")`; sweep,
  popcount, `all_zero?` stay in SVE assembly.
- The rule in `kernels.cr` holds: hand assembly needs a win on two
  microarchitectures of the same ISA before it ships.
