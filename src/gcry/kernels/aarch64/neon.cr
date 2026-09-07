# Advanced SIMD (NEON) is part of the AArch64 architectural baseline.
struct Gcry::Kernels::NEON < Gcry::Kernels::Base
  def tier : UInt8
    TIER_NEON
  end

  @[TargetFeature("+neon")]
  def sweep_words(occ : UInt64*, mark : UInt64*, n : Int32) : {UInt64, UInt64}
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return {0_u64, 0_u64} if n <= 0
    vector_n = n & ~1
    vector_count = vector_n.to_u64
    freed = 0_u64
    live = 0_u64
    if vector_n > 0
      asm(
        "mov x8, $2
         mov x9, $3
         mov x10, $4
         mov x11, xzr
         mov x12, xzr
         1:
         ld1 {v0.2d}, [x8]
         ld1 {v1.2d}, [x9]
         bic v2.16b, v0.16b, v1.16b
         st1 {v1.2d}, [x8], #16
         cnt v2.16b, v2.16b
         uaddlv h3, v2.16b
         umov w13, v3.h[0]
         add x11, x11, x13
         cnt v1.16b, v1.16b
         uaddlv h3, v1.16b
         umov w13, v3.h[0]
         add x12, x12, x13
         movi v0.2d, #0
         st1 {v0.2d}, [x9], #16
         subs w10, w10, #2
         b.ne 1b
         str x11, [$0]
         str x12, [$1]"
              :: "r"(pointerof(freed)), "r"(pointerof(live)), "r"(occ), "r"(mark), "r"(vector_count)
              : "x8", "x9", "x10", "x11", "x12", "x13", "v0", "v1", "v2", "v3", "memory", "cc"
              : "volatile"
      )
    end
    i = vector_n
    while i < n
      o = occ[i]
      m = mark[i]
      freed &+= (o & ~m).popcount.to_u64
      live &+= m.popcount.to_u64
      occ[i] = m
      mark[i] = 0_u64
      i += 1
    end
    {freed, live}
  end

  @[TargetFeature("+neon")]
  def popcount_words(words : UInt64*, n : Int32) : UInt64
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return 0_u64 if n <= 0
    vector_n = n & ~1
    vector_count = vector_n.to_u64
    acc = 0_u64
    if vector_n > 0
      asm(
        "mov x8, $1
         mov x9, $2
         mov x10, xzr
         1:
         ld1 {v0.2d}, [x8], #16
         cnt v0.16b, v0.16b
         uaddlv h1, v0.16b
         umov w11, v1.h[0]
         add x10, x10, x11
         subs w9, w9, #2
         b.ne 1b
         str x10, [$0]"
              :: "r"(pointerof(acc)), "r"(words), "r"(vector_count)
              : "x8", "x9", "x10", "x11", "v0", "v1", "memory", "cc"
              : "volatile"
      )
    end
    i = vector_n
    while i < n
      acc &+= words[i].popcount.to_u64
      i += 1
    end
    acc
  end

  @[TargetFeature("+neon")]
  def all_zero?(words : UInt64*, n : Int32) : Bool
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return true if n <= 0
    vector_n = n & ~1
    vector_count = vector_n.to_u64
    any = 0_u64
    if vector_n > 0
      asm(
        "mov x8, $1
         mov x9, $2
         movi v0.2d, #0
         1:
         ld1 {v1.2d}, [x8], #16
         orr v0.16b, v0.16b, v1.16b
         subs w9, w9, #2
         b.ne 1b
         ext v1.16b, v0.16b, v0.16b, #8
         orr v0.16b, v0.16b, v1.16b
         umov x10, v0.d[0]
         str x10, [$0]"
              :: "r"(pointerof(any)), "r"(words), "r"(vector_count)
              : "x8", "x9", "x10", "v0", "v1", "memory", "cc"
              : "volatile"
      )
      return false if any != 0
    end
    i = vector_n
    while i < n
      return false if words[i] != 0
      i += 1
    end
    true
  end

  @[TargetFeature("+neon")]
  def range_any?(ptr : UInt64*, n : Int32, lo : UInt64, span : UInt64) : Bool
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return false if n <= 0
    vector_n = n & ~1
    vector_count = vector_n.to_u64
    any = 0_u64
    if vector_n > 0
      asm(
        "mov x8, $1
         mov x9, $2
         mov x10, $3
         mov x11, $4
         dup v2.2d, x10
         dup v3.2d, x11
         movi v4.2d, #0
         1:
         ld1 {v0.2d}, [x8], #16
         sub v0.2d, v0.2d, v2.2d
         cmhi v0.2d, v3.2d, v0.2d
         orr v4.16b, v4.16b, v0.16b
         subs w9, w9, #2
         b.ne 1b
         ext v0.16b, v4.16b, v4.16b, #8
         orr v4.16b, v4.16b, v0.16b
         umov x10, v4.d[0]
         str x10, [$0]"
              :: "r"(pointerof(any)), "r"(ptr), "r"(vector_count), "r"(lo), "r"(span)
              : "x8", "x9", "x10", "x11", "v0", "v2", "v3", "v4", "memory", "cc"
              : "volatile"
      )
      return true if any != 0
    end
    i = vector_n
    while i < n
      return true if (ptr[i] &- lo) < span
      i += 1
    end
    false
  end
end
