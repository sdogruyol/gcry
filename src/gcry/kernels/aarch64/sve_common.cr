module Gcry::Kernels
  # SVE2 does not add a faster instruction for these four operations: SVE
  # already supplies predicated UInt64 loads/stores, bit operations, CNT and
  # reductions. Stamp the audited SVE loop under each backend's exact feature
  # contract so future SVE2-only changes remain isolated.
  macro define_sve_methods(features)
    @[TargetFeature({{features}})]
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

    @[TargetFeature({{features}})]
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

    @[TargetFeature({{features}})]
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

    @[TargetFeature({{features}})]
    def range_any?(ptr : UInt64*, n : Int32, lo : UInt64, span : UInt64) : Bool
      {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
      return false if n <= 0
      count = n.to_u64
      any = 0_u64
      asm(
        "mov x8, $1
         mov x9, $2
         mov x10, xzr
         mov x12, $3
         mov x13, $4
         dup z2.d, x12
         dup z3.d, x13
         1:
         whilelo p0.d, x10, x9
         b.eq 3f
         ld1d {z0.d}, p0/z, [x8, x10, lsl #3]
         sub z0.d, z0.d, z2.d
         cmplo p1.d, p0/z, z0.d, z3.d
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
              :: "r"(pointerof(any)), "r"(ptr), "r"(count), "r"(lo), "r"(span)
              : "x8", "x9", "x10", "x11", "x12", "x13", "z0", "z2", "z3", "p0", "p1", "memory", "cc"
              : "volatile"
      )
      any != 0
    end
  end
end
