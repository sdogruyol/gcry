# Scalable Vector Extension: predicated, vector-length-agnostic loops that
# accumulate in Z registers and reduce once with UADDV. LLVM does not
# vectorise for SVE without a `-mcpu`, so this is the only way to run SVE
# code from a generic AArch64 build. Selected on Linux from `AT_HWCAP`.
#
# SVE2 adds no instruction these four kernels can use, so there is no SVE2
# backend: an SVE2 host runs this one (measured at parity with the SVE
# stamping on a Neoverse-N2, `bench/log/linux/2026-09-08-neon-sve-ab`).
struct Gcry::Kernels::SVE < Gcry::Kernels::Base
  def tier : UInt8
    TIER_SVE
  end

  @[TargetFeature("+sve")]
  def sweep_words(occ : UInt64*, mark : UInt64*, n : Int32) : {UInt64, UInt64}
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return {0_u64, 0_u64} if n <= 0
    count = n.to_u64
    freed = 0_u64
    live = 0_u64
    asm(
      "mov x8, $2
       mov x9, $3
       mov x10, $4
       mov x11, xzr
       mov z4.d, #0
       mov z5.d, #0
       1:
       whilelo p0.d, x11, x10
       b.eq 2f
       ld1d {z0.d}, p0/z, [x8, x11, lsl #3]
       ld1d {z1.d}, p0/z, [x9, x11, lsl #3]
       bic z2.d, z0.d, z1.d
       cnt z2.d, p0/m, z2.d
       cnt z3.d, p0/m, z1.d
       add z4.d, p0/m, z4.d, z2.d
       add z5.d, p0/m, z5.d, z3.d
       st1d {z1.d}, p0, [x8, x11, lsl #3]
       mov z0.d, #0
       st1d {z0.d}, p0, [x9, x11, lsl #3]
       incd x11
       b 1b
       2:
       ptrue p1.d
       uaddv d0, p1, z4.d
       str d0, [$0]
       uaddv d0, p1, z5.d
       str d0, [$1]"
            :: "r"(pointerof(freed)), "r"(pointerof(live)), "r"(occ), "r"(mark), "r"(count)
            : "x8", "x9", "x10", "x11", "z0", "z1", "z2", "z3", "z4", "z5", "p0", "p1", "memory", "cc"
            : "volatile"
    )
    {freed, live}
  end

  @[TargetFeature("+sve")]
  def popcount_words(words : UInt64*, n : Int32) : UInt64
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return 0_u64 if n <= 0
    count = n.to_u64
    acc = 0_u64
    asm(
      "mov x8, $1
       mov x9, $2
       mov x10, xzr
       mov z2.d, #0
       1:
       whilelo p0.d, x10, x9
       b.eq 2f
       ld1d {z0.d}, p0/z, [x8, x10, lsl #3]
       cnt z0.d, p0/m, z0.d
       add z2.d, p0/m, z2.d, z0.d
       incd x10
       b 1b
       2:
       ptrue p1.d
       uaddv d0, p1, z2.d
       str d0, [$0]"
            :: "r"(pointerof(acc)), "r"(words), "r"(count)
            : "x8", "x9", "x10", "z0", "z2", "p0", "p1", "memory", "cc"
            : "volatile"
    )
    acc
  end

  @[TargetFeature("+sve")]
  def all_zero?(words : UInt64*, n : Int32) : Bool
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return true if n <= 0
    count = n.to_u64
    any = 0_u64
    asm(
      "mov x8, $1
       mov x9, $2
       mov x10, xzr
       1:
       whilelo p0.d, x10, x9
       b.eq 3f
       ld1d {z0.d}, p0/z, [x8, x10, lsl #3]
       cmpne p1.d, p0/z, z0.d, #0
       cntp x11, p0, p1.d
       cbnz x11, 2f
       incd x10
       b 1b
       2:
       mov x11, #1
       str x11, [$0]
       b 4f
       3:
       str xzr, [$0]
       4:"
            :: "r"(pointerof(any)), "r"(words), "r"(count)
            : "x8", "x9", "x10", "x11", "z0", "p0", "p1", "memory", "cc"
            : "volatile"
    )
    any == 0
  end

  # The predicated SVE loop with a per-iteration `cntp`/`cbnz` exit measured
  # half the vectorised NEON body on a Neoverse-N2 (21.9 vs 45.3 GB/s in L2,
  # `bench/log/linux/2026-09-08-neon-sve-ab`), so this one kernel stays on
  # the compiler's NEON code even on SVE hosts.
  Gcry::Kernels.def_autovec_range_any("+neon")
end
