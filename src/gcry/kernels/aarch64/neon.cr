# Advanced SIMD (NEON) is the AArch64 architectural baseline, and LLVM's loop
# vectoriser already turns the scalar bodies into `cnt`/`uaddlp` accumulation
# over Q registers with a single reduction at the end. This is the code that
# shipped through 0.24.0.
#
# Measured against #36's hand-written NEON on a Neoverse-N2, L2 GB/s, max of
# six rotated runs (`bench/log/linux/2026-09-08-neon-sve-ab`): all_zero 65.2
# vs 30.4, range_any 45.3 vs 27.3, sweep 20.5 vs 19.7, popcount 23.5 vs 26.6.
# The asm reduced through a GPR every 128 bits (`uaddlv` + `umov` + `add`),
# which is what the OR-reductions paid for. Its popcount was 13% ahead; that
# one block may come back with a second ARM microarchitecture (Apple Silicon)
# agreeing.
struct Gcry::Kernels::NEON < Gcry::Kernels::Base
  def tier : UInt8
    TIER_NEON
  end

  Gcry::Kernels.def_autovec_sweep("+neon")
  Gcry::Kernels.def_autovec_popcount("+neon")
  Gcry::Kernels.def_autovec_all_zero("+neon")
  Gcry::Kernels.def_autovec_range_any("+neon")
end
