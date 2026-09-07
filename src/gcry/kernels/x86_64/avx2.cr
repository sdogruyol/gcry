struct Gcry::Kernels::AVX2 < Gcry::Kernels::Base
  # AVX2 has no lane-wise UInt64 population count. Count both nibbles of every
  # byte through VPSHUFB, then use VPSADBW to widen each eight-byte group into
  # UInt64 accumulators. This keeps the sweep in vector registers instead of
  # extracting four lanes for scalar POPCNT on every iteration.
  def tier : UInt8
    TIER_AVX2
  end

  @[TargetFeature("+avx2,+bmi,+bmi2,+popcnt")]
  def sweep_words(occ : UInt64*, mark : UInt64*, n : Int32) : {UInt64, UInt64}
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return {0_u64, 0_u64} if n <= 0
    vector_n = n & ~3
    freed = 0_u64
    live = 0_u64
    if vector_n > 0
      asm(
        "movq $2, %r8
         movq $3, %r9
         movl $4, %ecx
         movabsq $$0x0f0f0f0f0f0f0f0f, %rax
         vmovq %rax, %xmm4
         vpbroadcastq %xmm4, %ymm4
         movabsq $$0x0302020102010100, %rax
         vmovq %rax, %xmm5
         movabsq $$0x0403030203020201, %rax
         vpinsrq $$1, %rax, %xmm5, %xmm5
         vinserti128 $$1, %xmm5, %ymm5, %ymm5
         vpxor %ymm6, %ymm6, %ymm6
         vpxor %ymm7, %ymm7, %ymm7
         vpxor %ymm8, %ymm8, %ymm8
         1:
         vmovdqu (%r8), %ymm0
         vmovdqu (%r9), %ymm1
         vpandn %ymm0, %ymm1, %ymm2
         vmovdqu %ymm1, (%r8)
         vmovdqu %ymm7, (%r9)
         vpand %ymm4, %ymm2, %ymm3
         vpsrlw $$4, %ymm2, %ymm9
         vpand %ymm4, %ymm9, %ymm9
         vpshufb %ymm3, %ymm5, %ymm3
         vpshufb %ymm9, %ymm5, %ymm9
         vpaddb %ymm9, %ymm3, %ymm3
         vpsadbw %ymm7, %ymm3, %ymm3
         vpaddq %ymm3, %ymm6, %ymm6
         vpand %ymm4, %ymm1, %ymm3
         vpsrlw $$4, %ymm1, %ymm9
         vpand %ymm4, %ymm9, %ymm9
         vpshufb %ymm3, %ymm5, %ymm3
         vpshufb %ymm9, %ymm5, %ymm9
         vpaddb %ymm9, %ymm3, %ymm3
         vpsadbw %ymm7, %ymm3, %ymm3
         vpaddq %ymm3, %ymm8, %ymm8
         addq $$32, %r8
         addq $$32, %r9
         subl $$4, %ecx
         jnz 1b
         vextracti128 $$1, %ymm6, %xmm0
         vpaddq %xmm0, %xmm6, %xmm6
         vpsrldq $$8, %xmm6, %xmm0
         vpaddq %xmm0, %xmm6, %xmm6
         vmovq %xmm6, %rax
         movq %rax, ($0)
         vextracti128 $$1, %ymm8, %xmm0
         vpaddq %xmm0, %xmm8, %xmm8
         vpsrldq $$8, %xmm8, %xmm0
         vpaddq %xmm0, %xmm8, %xmm8
         vmovq %xmm8, %rax
         movq %rax, ($1)
         vzeroupper"
              :: "r"(pointerof(freed)), "r"(pointerof(live)), "r"(occ), "r"(mark), "r"(vector_n)
              : "rax", "rcx", "r8", "r9", "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7", "xmm8", "xmm9", "memory", "cc"
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

  @[TargetFeature("+avx2,+bmi,+bmi2,+popcnt")]
  def popcount_words(words : UInt64*, n : Int32) : UInt64
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return 0_u64 if n <= 0
    acc = 0_u64
    # Materialising the nibble lookup table is not worthwhile below two YMM
    # vectors. Keep those uncommon, larger-class bitmaps on direct POPCNT.
    if n < 8
      asm(
        "movq $1, %r8
         movl $2, %ecx
         xorq %r10, %r10
         1:
         popcntq (%r8), %rax
         addq %rax, %r10
         addq $$8, %r8
         decl %ecx
         jnz 1b
         movq %r10, ($0)"
              :: "r"(pointerof(acc)), "r"(words), "r"(n)
              : "rax", "rcx", "r8", "r10", "memory", "cc"
              : "volatile"
      )
      return acc
    end
    vector_n = n & ~3
    if vector_n > 0
      asm(
        "movq $1, %r8
         movl $2, %ecx
         movabsq $$0x0f0f0f0f0f0f0f0f, %rax
         vmovq %rax, %xmm4
         vpbroadcastq %xmm4, %ymm4
         movabsq $$0x0302020102010100, %rax
         vmovq %rax, %xmm5
         movabsq $$0x0403030203020201, %rax
         vpinsrq $$1, %rax, %xmm5, %xmm5
         vinserti128 $$1, %xmm5, %ymm5, %ymm5
         vpxor %ymm6, %ymm6, %ymm6
         vpxor %ymm7, %ymm7, %ymm7
         1:
         vmovdqu (%r8), %ymm0
         vpand %ymm4, %ymm0, %ymm1
         vpsrlw $$4, %ymm0, %ymm2
         vpand %ymm4, %ymm2, %ymm2
         vpshufb %ymm1, %ymm5, %ymm1
         vpshufb %ymm2, %ymm5, %ymm2
         vpaddb %ymm2, %ymm1, %ymm1
         vpsadbw %ymm7, %ymm1, %ymm1
         vpaddq %ymm1, %ymm6, %ymm6
         addq $$32, %r8
         subl $$4, %ecx
         jnz 1b
         vextracti128 $$1, %ymm6, %xmm0
         vpaddq %xmm0, %xmm6, %xmm6
         vpsrldq $$8, %xmm6, %xmm0
         vpaddq %xmm0, %xmm6, %xmm6
         vmovq %xmm6, %rax
         movq %rax, ($0)
         vzeroupper"
              :: "r"(pointerof(acc)), "r"(words), "r"(vector_n)
              : "rax", "rcx", "r8", "xmm0", "xmm1", "xmm2", "xmm4", "xmm5", "xmm6", "xmm7", "memory", "cc"
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

  @[TargetFeature("+avx2,+bmi,+bmi2,+popcnt")]
  def all_zero?(words : UInt64*, n : Int32) : Bool
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return true if n <= 0
    vector_n = n & ~3
    any = 0_u8
    if vector_n > 0
      asm(
        "movq $1, %r8
         movl $2, %ecx
         vpxor %ymm0, %ymm0, %ymm0
         1:
         vpor (%r8), %ymm0, %ymm0
         addq $$32, %r8
         subl $$4, %ecx
         jnz 1b
         vptest %ymm0, %ymm0
         setnz ($0)
         vzeroupper"
              :: "r"(pointerof(any)), "r"(words), "r"(vector_n)
              : "rcx", "r8", "xmm0", "memory", "cc"
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

  @[TargetFeature("+avx2,+bmi,+bmi2,+popcnt")]
  def range_any?(ptr : UInt64*, n : Int32, lo : UInt64, span : UInt64) : Bool
    {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
    return false if n <= 0
    vector_n = n & ~3
    any = 0_u8
    if vector_n > 0
      asm(
        "movq $1, %r8
         movl $2, %ecx
         vmovq $3, %xmm4
         vpbroadcastq %xmm4, %ymm4
         vmovq $4, %xmm5
         vpbroadcastq %xmm5, %ymm5
         movabsq $$0x8000000000000000, %rax
         vmovq %rax, %xmm6
         vpbroadcastq %xmm6, %ymm6
         vpxor %ymm6, %ymm5, %ymm5
         vpxor %ymm7, %ymm7, %ymm7
         1:
         vmovdqu (%r8), %ymm0
         vpsubq %ymm4, %ymm0, %ymm0
         vpxor %ymm6, %ymm0, %ymm0
         vpcmpgtq %ymm0, %ymm5, %ymm1
         vpor %ymm1, %ymm7, %ymm7
         addq $$32, %r8
         subl $$4, %ecx
         jnz 1b
         vptest %ymm7, %ymm7
         setnz ($0)
         vzeroupper"
              :: "r"(pointerof(any)), "r"(ptr), "r"(vector_n), "r"(lo), "r"(span)
              : "rax", "rcx", "r8", "xmm0", "xmm1", "xmm4", "xmm5", "xmm6", "xmm7", "memory", "cc"
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
