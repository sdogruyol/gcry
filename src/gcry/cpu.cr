require "./kernels"

module Gcry
  # Which SIMD tier this CPU can actually run.
  #
  # Calling a `@[TargetFeature]` clone on a CPU without the feature is SIGILL,
  # not a graceful fallback, so this runs once at `Heap#initialize` and the
  # answer is carried as a `UInt8`. There is no lazy memoisation and no `once`
  # constant: `size_classes.cr` records why — this code can run before `Fiber`
  # is up under `-Dgc_none`, and a runtime constant initializer deadlocks there.
  module Cpu
    # x86_64 needs both the CPU bits (cpuid leaf 7) and OS support for the wider
    # register state (xcr0 via xgetbv). A kernel that saves only SSE state will
    # corrupt ymm/zmm across a context switch, so `osxsave` + the xcr0 bits are
    # part of the feature test, not a nicety.
    XCR0_SSE       = 1_u64 << 1
    XCR0_AVX       = 1_u64 << 2
    XCR0_OPMASK    = 1_u64 << 5
    XCR0_ZMM_HI256 = 1_u64 << 6
    XCR0_HI16_ZMM  = 1_u64 << 7

    XCR0_AVX_MASK    = XCR0_SSE | XCR0_AVX
    XCR0_AVX512_MASK = XCR0_AVX_MASK | XCR0_OPMASK | XCR0_ZMM_HI256 | XCR0_HI16_ZMM

    # Highest tier this host can execute, ignoring any override.
    def self.detect : UInt8
      {% if flag?(:x86_64) %}
        detect_x86
      {% elsif flag?(:aarch64) %}
        # NEON is ARMv8-A baseline: no detection, no clones, and the scalar
        # body is what LLVM vectorises. SVE would need a real variant and does
        # not pay for one yet.
        Kernels::TIER_NEON
      {% else %}
        Kernels::TIER_SCALAR
      {% end %}
    end

    # Resolve `GCRY_SIMD` against what the host can run. The override only ever
    # clamps *down*: naming a tier this CPU lacks would turn a knob into a
    # SIGILL, so an unknown or unsupported value falls back to the detected
    # tier rather than being honoured.
    def self.resolve(override : String?) : UInt8
      detected = detect
      return detected unless override
      requested = case override
                  when "off", "scalar", "none" then Kernels::TIER_SCALAR
                  when "neon"                  then Kernels::TIER_NEON
                  when "avx2"                  then Kernels::TIER_AVX2
                  when "avx512"                then Kernels::TIER_AVX512
                  else                              detected
                  end
      requested < detected ? requested : detected
    end

    # `GCRY_SIMD` read the only way it can be read here.
    #
    # This runs from `Heap#initialize`, which under `-Dgc_none` runs inside
    # `GC.init` — before `Fiber` exists. Crystal's `ENV[]` uses `once` and
    # allocates, and `gc_override.cr:520` records what that does at this point
    # in startup ("ENV[] allocates and can SEGV during GC.init"). So this
    # compares the raw `LibC.getenv` bytes and never builds a `String`.
    def self.tier_from_env : UInt8
      raw = LibC.getenv("GCRY_SIMD")
      return detect if raw.null?

      detected = detect
      requested = if env_is?(raw, "off") || env_is?(raw, "scalar") || env_is?(raw, "none")
                    Kernels::TIER_SCALAR
                  elsif env_is?(raw, "neon")
                    Kernels::TIER_NEON
                  elsif env_is?(raw, "avx2")
                    Kernels::TIER_AVX2
                  elsif env_is?(raw, "avx512")
                    Kernels::TIER_AVX512
                  else
                    detected
                  end
      requested < detected ? requested : detected
    end

    private def self.env_is?(raw : UInt8*, want : String) : Bool
      i = 0
      while i < want.bytesize
        return false if raw[i] != want.to_unsafe[i]
        i += 1
      end
      raw[want.bytesize] == 0_u8
    end

    def self.tier_name(tier : UInt8) : String
      case tier
      when Kernels::TIER_AVX512 then "avx512"
      when Kernels::TIER_AVX2   then "avx2"
      when Kernels::TIER_NEON   then "neon"
      else                           "scalar"
      end
    end

    {% if flag?(:x86_64) %}
      private def self.detect_x86 : UInt8
        max_leaf, _, _, _ = cpuid(0_u32, 0_u32)
        return Kernels::TIER_SCALAR if max_leaf < 7

        _, _, ecx1, _ = cpuid(1_u32, 0_u32)
        osxsave = (ecx1 & (1_u32 << 27)) != 0
        avx_cpu = (ecx1 & (1_u32 << 28)) != 0
        return Kernels::TIER_SCALAR unless osxsave && avx_cpu

        xcr0 = xgetbv0
        return Kernels::TIER_SCALAR if (xcr0 & XCR0_AVX_MASK) != XCR0_AVX_MASK

        _, ebx7, ecx7, _ = cpuid(7_u32, 0_u32)
        avx2 = (ebx7 & (1_u32 << 5)) != 0
        return Kernels::TIER_SCALAR unless avx2

        avx512f = (ebx7 & (1_u32 << 16)) != 0
        avx512bw = (ebx7 & (1_u32 << 30)) != 0
        avx512vl = (ebx7 & (1_u32 << 31)) != 0
        vpopcntdq = (ecx7 & (1_u32 << 14)) != 0

        # AVX-512 is only worth a tier where the popcount actually lowers to
        # `vpopcntq`; without VPOPCNTDQ the 512-bit clone is the AVX2 clone with
        # a worse frequency licence.
        if avx512f && avx512bw && avx512vl && vpopcntdq &&
           (xcr0 & XCR0_AVX512_MASK) == XCR0_AVX512_MASK
          Kernels::TIER_AVX512
        else
          Kernels::TIER_AVX2
        end
      end

      private def self.cpuid(leaf : UInt32, subleaf : UInt32) : {UInt32, UInt32, UInt32, UInt32}
        eax = uninitialized UInt32
        ebx = uninitialized UInt32
        ecx = uninitialized UInt32
        edx = uninitialized UInt32
        asm("cpuid"
                : "={eax}"(eax), "={ebx}"(ebx), "={ecx}"(ecx), "={edx}"(edx)
                : "{eax}"(leaf), "{ecx}"(subleaf)
                :: "volatile")
        {eax, ebx, ecx, edx}
      end

      private def self.xgetbv0 : UInt64
        lo = uninitialized UInt32
        hi = uninitialized UInt32
        asm("xgetbv" : "={eax}"(lo), "={edx}"(hi) : "{ecx}"(0_u32) :: "volatile")
        (hi.to_u64 << 32) | lo.to_u64
      end
    {% end %}
  end
end
