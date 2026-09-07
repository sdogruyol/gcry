module Gcry
  # LLVM intrinsics the kernels need that Crystal's `Intrinsics` does not expose.
  # The three trailing arguments to llvm.prefetch are `immarg`, so the wrappers
  # below keep them literal at every call site.
  lib LibGcryIntrinsics
    fun prefetch = "llvm.prefetch.p0"(address : Void*, rw : Int32, locality : Int32, cache_type : Int32)
  end

  # Streaming bitmap kernels for the collector.
  #
  # `Base` is an abstract struct because Heap is initialized before Fiber under
  # `-Dgc_none`: selecting a backend must not allocate. Heap stores the selected
  # value once and calls through this interface. Each bitmap operation loads the
  # receiver tag directly instead of passing a UInt8 through a module dispatcher.
  module Kernels
    TIER_SCALAR = 0_u8
    TIER_NEON   = 1_u8
    TIER_SVE    = 2_u8
    TIER_AVX2   = 3_u8
    TIER_AVX512 = 4_u8

    abstract struct Base
      abstract def tier : UInt8
      abstract def sweep_words(occ : UInt64*, mark : UInt64*, n : Int32) : {UInt64, UInt64}
      abstract def popcount_words(words : UInt64*, n : Int32) : UInt64
      abstract def all_zero?(words : UInt64*, n : Int32) : Bool
      abstract def range_any?(ptr : UInt64*, n : Int32, lo : UInt64, span : UInt64) : Bool
    end

    # The loop bodies below are what `Scalar` runs and what LLVM's loop
    # vectoriser takes when stamped under a `@[TargetFeature]`: fixed stride,
    # no early exit, raw pointers, integer reductions. A backend uses these
    # wherever the compiler's output is at least as fast as hand assembly on
    # every microarchitecture it was measured on — on Zen 5 the vectoriser's
    # multi-accumulator unroll beat the single-accumulator asm from #36 by
    # 21–52% in L2 on everything but the AVX2 sweep
    # (`bench/log/linux/2026-09-07-kernel-backend-ab`). Hand assembly earns its
    # place only with an A/B on both an Intel and an AMD part.
    #
    # `-Dgcry_kernels_broken` is the positive control for `make kernels-broken`:
    # it drops the last word from every vector backend so the equivalence fuzz
    # must go red. The perturbation is stamped here and in the asm backends,
    # never in `Scalar`, which is the oracle.
    macro def_autovec_sweep(features)
      @[TargetFeature({{features}})]
      def sweep_words(occ : UInt64*, mark : UInt64*, n : Int32) : {UInt64, UInt64}
        {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
        freed = 0_u64
        live = 0_u64
        i = 0
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
    end

    macro def_autovec_popcount(features)
      @[TargetFeature({{features}})]
      def popcount_words(words : UInt64*, n : Int32) : UInt64
        {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
        acc = 0_u64
        i = 0
        while i < n
          acc &+= words[i].popcount.to_u64
          i += 1
        end
        acc
      end
    end

    macro def_autovec_all_zero(features)
      @[TargetFeature({{features}})]
      def all_zero?(words : UInt64*, n : Int32) : Bool
        {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
        acc = 0_u64
        i = 0
        while i < n
          acc |= words[i]
          i += 1
        end
        acc == 0_u64
      end
    end

    macro def_autovec_range_any(features)
      @[TargetFeature({{features}})]
      def range_any?(ptr : UInt64*, n : Int32, lo : UInt64, span : UInt64) : Bool
        {% if flag?(:gcry_kernels_broken) %} n -= 1 if n > 1 {% end %}
        acc = 0_u64
        i = 0
        while i < n
          acc |= ((ptr[i] &- lo) < span) ? 1_u64 : 0_u64
          i += 1
        end
        acc != 0_u64
      end
    end

    # Turn the detected tier into an allocation-free backend value once, during
    # Heap initialization. Unsupported tier values safely select Scalar.
    def self.for_tier(tier : UInt8) : Base
      {% if flag?(:x86_64) %}
        case tier
        when TIER_AVX512 then AVX512.new
        when TIER_AVX2   then AVX2.new
        else                  Scalar.new
        end
      {% elsif flag?(:aarch64) %}
        case tier
        when TIER_SVE  then SVE.new
        when TIER_NEON then NEON.new
        else                Scalar.new
        end
      {% else %}
        Scalar.new
      {% end %}
    end

    @[AlwaysInline]
    def self.prefetch_read(address : Void*) : Nil
      LibGcryIntrinsics.prefetch(address, 0, 3, 1)
    end

    @[AlwaysInline]
    def self.prefetch_write(address : Void*) : Nil
      LibGcryIntrinsics.prefetch(address, 1, 3, 1)
    end
  end
end

require "./kernels/scalar"

{% if flag?(:x86_64) %}
  require "./kernels/x86_64/*"
{% elsif flag?(:aarch64) %}
  require "./kernels/aarch64/neon"
  require "./kernels/aarch64/sve"
{% end %}
