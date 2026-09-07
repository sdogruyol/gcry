# Advanced SIMD (NEON) is the AArch64 architectural baseline, and LLVM's loop
# vectoriser already turns the scalar bodies into `cnt`/`uaddlp` accumulation
# over Q registers with a single reduction at the end. This is the code that
# shipped through 0.24.0.
#
# Hand assembly replaced it briefly (#36) but reduced through a GPR every 128
# bits (`uaddlv` + `umov` + `add` per two words) and was never A/B'd on native
# ARM. Until such an A/B shows a win, the compiler's output is the backend.
struct Gcry::Kernels::NEON < Gcry::Kernels::Base
  def tier : UInt8
    TIER_NEON
  end

  Gcry::Kernels.def_autovec_sweep("+neon")
  Gcry::Kernels.def_autovec_popcount("+neon")
  Gcry::Kernels.def_autovec_all_zero("+neon")
  Gcry::Kernels.def_autovec_range_any("+neon")
end
