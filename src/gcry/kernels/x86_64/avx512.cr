# With `+avx512vpopcntdq` LLVM lowers `ctpop <8 x i64>` straight to VPOPCNTQ,
# so the vectorised loops already are the instruction sequence hand assembly
# would write, plus an unroll with independent accumulators. The #36 asm
# measured behind them on Zen 5 in L2: sweep -11%, popcount -14%, all_zero
# -28%, range_any -28% (`make bench-kernels`, 2026-09-07). Nothing here is
# hand-written until an A/B on both an Intel and an AMD part says otherwise.
struct Gcry::Kernels::AVX512 < Gcry::Kernels::Base
  def tier : UInt8
    TIER_AVX512
  end

  Gcry::Kernels.def_autovec_sweep("+avx512f,+avx512bw,+avx512vl,+avx512vpopcntdq")
  Gcry::Kernels.def_autovec_popcount("+avx512f,+avx512bw,+avx512vl,+avx512vpopcntdq")
  Gcry::Kernels.def_autovec_all_zero("+avx512f,+avx512bw,+avx512vl,+avx512vpopcntdq")
  Gcry::Kernels.def_autovec_range_any("+avx512f,+avx512bw,+avx512vl,+avx512vpopcntdq")
end
