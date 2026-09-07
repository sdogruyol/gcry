struct Gcry::Kernels::AVX512 < Gcry::Kernels::Base
  def tier : UInt8
    TIER_AVX512
  end

  @[TargetFeature("+avx512f,+avx512bw,+avx512vl,+avx512vpopcntdq")]
  def sweep_words(occ : UInt64*, mark : UInt64*, n : Int32) : {UInt64, UInt64}
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return {0_u64, 0_u64} if n <= 0
    vector_n = n & ~7
    freed = 0_u64
    live = 0_u64
    if vector_n > 0
      asm(
        "movq $2, %r8
         movq $3, %r9
         movl $4, %ecx
         vpxord %zmm4, %zmm4, %zmm4
         vpxord %zmm5, %zmm5, %zmm5
         1:
         vmovdqu64 (%r8), %zmm0
         vmovdqu64 (%r9), %zmm1
         vpandnq %zmm0, %zmm1, %zmm2
         vpopcntq %zmm2, %zmm2
         vpaddq %zmm2, %zmm4, %zmm4
         vpopcntq %zmm1, %zmm3
         vpaddq %zmm3, %zmm5, %zmm5
         vmovdqu64 %zmm1, (%r8)
         vpxord %zmm0, %zmm0, %zmm0
         vmovdqu64 %zmm0, (%r9)
         addq $$64, %r8
         addq $$64, %r9
         subl $$8, %ecx
         jnz 1b
         vextracti64x4 $$1, %zmm4, %ymm0
         vpaddq %ymm0, %ymm4, %ymm4
         vextracti128 $$1, %ymm4, %xmm0
         vpaddq %xmm0, %xmm4, %xmm4
         vpsrldq $$8, %xmm4, %xmm0
         vpaddq %xmm0, %xmm4, %xmm4
         vmovq %xmm4, %rax
         movq %rax, ($0)
         vextracti64x4 $$1, %zmm5, %ymm0
         vpaddq %ymm0, %ymm5, %ymm5
         vextracti128 $$1, %ymm5, %xmm0
         vpaddq %xmm0, %xmm5, %xmm5
         vpsrldq $$8, %xmm5, %xmm0
         vpaddq %xmm0, %xmm5, %xmm5
         vmovq %xmm5, %rax
         movq %rax, ($1)
         vzeroupper"
              :: "r"(pointerof(freed)), "r"(pointerof(live)), "r"(occ), "r"(mark), "r"(vector_n)
              : "rax", "rcx", "r8", "r9", "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "memory", "cc"
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

  @[TargetFeature("+avx512f,+avx512bw,+avx512vl,+avx512vpopcntdq")]
  def popcount_words(words : UInt64*, n : Int32) : UInt64
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return 0_u64 if n <= 0
    vector_n = n & ~7
    acc = 0_u64
    if vector_n > 0
      # Two accumulators hide VPOPCNTQ/add latency on the common 64-word
      # class-0 bitmap. Shorter bitmaps stay on the smaller single stream.
      asm(
        "movq $1, %r8
         movl $2, %ecx
         vpxord %zmm2, %zmm2, %zmm2
         cmpl $$64, %ecx
         jb 3f
         vpxord %zmm3, %zmm3, %zmm3
         1:
         vmovdqu64 (%r8), %zmm0
         vmovdqu64 64(%r8), %zmm1
         vpopcntq %zmm0, %zmm0
         vpopcntq %zmm1, %zmm1
         vpaddq %zmm0, %zmm2, %zmm2
         vpaddq %zmm1, %zmm3, %zmm3
         addq $$128, %r8
         subl $$16, %ecx
         cmpl $$16, %ecx
         jae 1b
         vpaddq %zmm3, %zmm2, %zmm2
         testl $$8, %ecx
         jz 4f
         vmovdqu64 (%r8), %zmm0
         vpopcntq %zmm0, %zmm0
         vpaddq %zmm0, %zmm2, %zmm2
         jmp 4f
         3:
         vmovdqu64 (%r8), %zmm0
         vpopcntq %zmm0, %zmm0
         vpaddq %zmm0, %zmm2, %zmm2
         addq $$64, %r8
         subl $$8, %ecx
         jnz 3b
         4:
         vextracti64x4 $$1, %zmm2, %ymm0
         vpaddq %ymm0, %ymm2, %ymm2
         vextracti128 $$1, %ymm2, %xmm0
         vpaddq %xmm0, %xmm2, %xmm2
         vpsrldq $$8, %xmm2, %xmm0
         vpaddq %xmm0, %xmm2, %xmm2
         vmovq %xmm2, %rax
         movq %rax, ($0)
         vzeroupper"
              :: "r"(pointerof(acc)), "r"(words), "r"(vector_n)
              : "rax", "rcx", "r8", "xmm0", "xmm1", "xmm2", "xmm3", "memory", "cc"
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

  @[TargetFeature("+avx512f,+avx512bw,+avx512vl,+avx512vpopcntdq")]
  def all_zero?(words : UInt64*, n : Int32) : Bool
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return true if n <= 0
    vector_n = n & ~7
    any = 0_u64
    if vector_n > 0
      asm(
        "movq $1, %r8
         movl $2, %ecx
         vpxord %zmm0, %zmm0, %zmm0
         1:
         vporq (%r8), %zmm0, %zmm0
         addq $$64, %r8
         subl $$8, %ecx
         jnz 1b
         vextracti64x4 $$1, %zmm0, %ymm1
         vpor %ymm1, %ymm0, %ymm0
         vextracti128 $$1, %ymm0, %xmm1
         vpor %xmm1, %xmm0, %xmm0
         vpsrldq $$8, %xmm0, %xmm1
         vpor %xmm1, %xmm0, %xmm0
         vmovq %xmm0, %rax
         movq %rax, ($0)
         vzeroupper"
              :: "r"(pointerof(any)), "r"(words), "r"(vector_n)
              : "rax", "rcx", "r8", "xmm0", "xmm1", "memory", "cc"
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

  @[TargetFeature("+avx512f,+avx512bw,+avx512vl,+avx512vpopcntdq")]
  def range_any?(ptr : UInt64*, n : Int32, lo : UInt64, span : UInt64) : Bool
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return false if n <= 0
    vector_n = n & ~7
    hits = 0_u32
    if vector_n > 0
      asm(
        "movq $1, %r8
         movl $2, %ecx
         vmovq $3, %xmm4
         vpbroadcastq %xmm4, %zmm4
         vmovq $4, %xmm5
         vpbroadcastq %xmm5, %zmm5
         xorl %r10d, %r10d
         1:
         vmovdqu64 (%r8), %zmm0
         vpsubq %zmm4, %zmm0, %zmm0
         vpcmpuq $$1, %zmm5, %zmm0, %k1
         kmovw %k1, %eax
         orl %eax, %r10d
         addq $$64, %r8
         subl $$8, %ecx
         jnz 1b
         movl %r10d, ($0)
         vzeroupper"
              :: "r"(pointerof(hits)), "r"(ptr), "r"(vector_n), "r"(lo), "r"(span)
              : "rax", "rcx", "r8", "r10", "xmm0", "xmm4", "xmm5", "k1", "memory", "cc"
              : "volatile"
      )
      return true if hits != 0
    end
    i = vector_n
    while i < n
      return true if (ptr[i] &- lo) < span
      i += 1
    end
    false
  end
end
