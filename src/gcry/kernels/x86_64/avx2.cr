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

  # LLVM's own vpshufb/vpsadbw popcount, unrolled with independent
  # accumulators, beat the single-accumulator asm on Zen 5 (asm was -25%
  # popcount, -52% all_zero, -44% range_any in L2; the sweep asm above was at
  # parity, -9%, and claims +40% on Intel). `def_autovec_*` in kernels.cr;
  # numbers in `bench/log/linux/2026-09-07-kernel-backend-ab`.
  Gcry::Kernels.def_autovec_popcount("+avx2,+bmi,+bmi2,+popcnt")
  Gcry::Kernels.def_autovec_all_zero("+avx2,+bmi,+bmi2,+popcnt")
  Gcry::Kernels.def_autovec_range_any("+avx2,+bmi,+bmi2,+popcnt")
end
