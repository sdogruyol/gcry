module Gcry
  # LLVM intrinsics the kernels need that Crystal's `Intrinsics` does not expose.
  #
  # `llvm.prefetch.p0` takes three `immarg` operands, so every call site must
  # pass literal constants — `Kernels.prefetch_read` / `#prefetch_write` below
  # are the only callers, and they hardcode them. Verified to emit `prefetcht0`
  # on x86_64 and `PRFM PSTL1KEEP` on aarch64.
  lib LibGcryIntrinsics
    fun prefetch = "llvm.prefetch.p0"(address : Void*, rw : Int32, locality : Int32, cache_type : Int32)
  end

  # Streaming bitmap kernels for the collector.
  #
  # Crystal cannot express vector types, so there are no hand-written
  # intrinsics here. Every kernel is a plain `UInt64` word loop written so that
  # LLVM's loop vectoriser will take it — fixed stride, no early exit, raw
  # `UInt64*` rather than `Slice`, and reductions that are associative under
  # `-ffast-math`-free integer arithmetic. `def_kernel` then stamps the *same
  # body* into one clone per instruction-set tier under `@[TargetFeature]`, and
  # the dispatcher picks a tier once, at `Heap#initialize`.
  #
  # The scalar clone is not dead weight even though a CPU without the baseline
  # falls back to gcry's header path rather than to scalar bitmaps: it is the
  # oracle `spec/kernels_spec.cr` fuzzes the vector clones against, and
  # `GCRY_SIMD=scalar` keeps the one A/B that separates "the vector kernels are
  # wrong" from "the representation is wrong".
  #
  # aarch64 needs no clones at all — NEON is architectural baseline, so the
  # scalar body *is* the NEON body and LLVM vectorises it unconditionally.
  module Kernels
    # Instruction-set tier, chosen once and stored as a UInt8 rather than a
    # `Proc` per kernel. Two reasons, neither of them speed: `size_classes.cr`
    # records the house rule that this code runs before `Fiber` is up, so a
    # plain integer is the safe shape; and a `case` on a UInt8 is legible in
    # `--emit llvm-ir`, which is how the vectorisation gate reads the build.
    TIER_SCALAR = 0_u8
    TIER_NEON   = 1_u8
    TIER_AVX2   = 2_u8
    TIER_AVX512 = 3_u8

    # Stamp one body into a scalar clone plus, on x86_64, an AVX2 and an
    # AVX-512 clone. Calling a clone on a CPU without its features is SIGILL,
    # so the only caller is the dispatcher below.
    #
    # `-Dgcry_kernels_broken` is the positive control for `make kernels-broken`.
    # It drops the last word from the **vector clones only**, which is the
    # smallest perturbation that leaves them compiling and running while making
    # them disagree with the scalar oracle. A green equivalence fuzz is worth
    # nothing until this flag has been observed red, and the flag is inert in
    # every build that does not name it. Every kernel takes `n : Int32`, which
    # is what makes one perturbation cover all of them.
    macro def_kernel(name, sig, ret, &body)
      def self.{{name.id}}_scalar({{sig.id}}) : {{ret.id}}
        {{body.body}}
      end

      {% if flag?(:x86_64) %}
        @[TargetFeature("+avx2,+bmi,+bmi2,+popcnt")]
        def self.{{name.id}}_avx2({{sig.id}}) : {{ret.id}}
          {% if flag?(:gcry_kernels_broken) %} n = n - 1 if n > 1 {% end %}
          {{body.body}}
        end

        @[TargetFeature("+avx512f,+avx512bw,+avx512vl,+avx512vpopcntdq")]
        def self.{{name.id}}_avx512({{sig.id}}) : {{ret.id}}
          {% if flag?(:gcry_kernels_broken) %} n = n - 1 if n > 1 {% end %}
          {{body.body}}
        end
      {% end %}
    end

    # Dispatch `name` on `tier`. One predictable branch per chunk, never per
    # word: the kernels are called once for a whole bitmap.
    macro dispatch(name, tier, *args)
      {% if flag?(:x86_64) %}
        case {{tier}}
        when TIER_AVX512 then {{name.id}}_avx512({{args.splat}})
        when TIER_AVX2   then {{name.id}}_avx2({{args.splat}})
        else                  {{name.id}}_scalar({{args.splat}})
        end
      {% else %}
        {{name.id}}_scalar({{args.splat}})
      {% end %}
    end

    # ------------------------------------------------------------------
    # Sweep: consume one chunk's mark bitmap into its occupancy bitmap.
    #
    #   occ[i] = mark[i]   — survivors become the new allocated set
    #   mark[i] = 0        — cleared in the same pass, so there is no
    #                        separate clear phase at all
    #
    # Returns {freed_blocks, live_blocks}. Those popcounts are what replace
    # the per-block header walk: fill buckets, live/free payload and the
    # fully-dead decision all fall out of them.
    #
    # This is the one kernel that must never clear an individual bit — a
    # per-bit clear races a mutator setting a different bit in the same word
    # (see R2 in the plan). The whole-word store is what makes it safe.
    # ------------------------------------------------------------------
    def_kernel(sweep_words, "occ : UInt64*, mark : UInt64*, n : Int32", "{UInt64, UInt64}") do
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

    # Count set bits over `n` words. Used for live-object counts and for the
    # `popcount(occ) == 0` assertion on dormant-chunk revival.
    def_kernel(popcount_words, "words : UInt64*, n : Int32", "UInt64") do
      acc = 0_u64
      i = 0
      while i < n
        acc &+= words[i].popcount.to_u64
        i += 1
      end
      acc
    end

    # True when every one of `n` words is zero. An OR-reduction, which is how
    # "is this page run free?" becomes a few vector ops instead of a walk over
    # every block header covering the run.
    def_kernel(all_zero, "words : UInt64*, n : Int32", "Bool") do
      acc = 0_u64
      i = 0
      while i < n
        acc |= words[i]
        i += 1
      end
      acc == 0_u64
    end

    # Conservative-scan pre-filter: does any of the `n` words at `ptr` fall in
    # `[lo, lo + span)`?
    #
    # Crystal cannot express `movemask`, so this is deliberately NOT the
    # compress-and-iterate shape `simdgc.c#gc_scan_range` uses. It is an
    # OR-reduction that lets the caller reject a whole group of words with one
    # branch and drop to the scalar path only for groups that hit. On
    # pointer-dense stacks most groups hit and the filter is pure overhead,
    # which is why it is measured before being wired into `Roots.scan_range`.
    #
    # `w &- lo < span` is the usual unsigned range test: one subtract, one
    # compare, no branch, and it vectorises.
    def_kernel(range_any, "ptr : UInt64*, n : Int32, lo : UInt64, span : UInt64", "Bool") do
      acc = 0_u64
      i = 0
      while i < n
        acc |= ((ptr[i] &- lo) < span) ? 1_u64 : 0_u64
        i += 1
      end
      acc != 0_u64
    end

    # ------------------------------------------------------------------
    # Dispatchers. These are the only entry points collector code calls.
    # ------------------------------------------------------------------

    def self.sweep_words(occ : UInt64*, mark : UInt64*, n : Int32, tier : UInt8) : {UInt64, UInt64}
      dispatch(sweep_words, tier, occ, mark, n)
    end

    def self.popcount_words(words : UInt64*, n : Int32, tier : UInt8) : UInt64
      dispatch(popcount_words, tier, words, n)
    end

    def self.all_zero?(words : UInt64*, n : Int32, tier : UInt8) : Bool
      dispatch(all_zero, tier, words, n)
    end

    def self.range_any?(ptr : UInt64*, n : Int32, lo : UInt64, span : UInt64, tier : UInt8) : Bool
      dispatch(range_any, tier, ptr, n, lo, span)
    end

    # ------------------------------------------------------------------
    # Prefetch. `locality = 3` keeps the line in all cache levels, which is
    # what a mark pipeline wants; `cache_type = 1` is the data cache.
    # ------------------------------------------------------------------

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
