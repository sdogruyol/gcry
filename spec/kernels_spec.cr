require "./spec_helper"

# Equivalence fuzz for the SIMD bitmap kernels.
#
# The vector clones are stamped from the same source body as the scalar one, so
# a divergence means the *compiler* did something the body did not say — a
# vectoriser bug, a bad `@[TargetFeature]` set, or a reduction that is not
# actually associative. That is exactly the class of defect a hand-written
# assertion would never find, so the gate is a fuzz against the scalar oracle
# rather than against expected values.
#
# `make kernels-broken` is the other half: it perturbs a vector clone and this
# file must go red. A green run here is only worth something because that one
# has been observed red.
private def each_tier(& : UInt8 ->)
  detected = Gcry::Cpu.detect
  tier = Gcry::Kernels::TIER_SCALAR
  while tier <= detected
    yield tier
    tier += 1
  end
end

private def fill_pair(rng : Random, n : Int32, density : Int32) : {Pointer(UInt64), Pointer(UInt64)}
  occ = Pointer(UInt64).malloc(n)
  mark = Pointer(UInt64).malloc(n)
  n.times do |i|
    o = case density
        when 0 then 0_u64
        when 1 then UInt64::MAX
        else        rng.rand(UInt64::MAX)
        end
    # `mark` is always a subset of `occ`: the collector cannot mark a block it
    # never allocated, and a kernel that only works on that subset relation is
    # the one we ship.
    mark[i] = o & rng.rand(UInt64::MAX)
    occ[i] = o
  end
  {occ, mark}
end

describe Gcry::Kernels do
  it "sweep_words: every tier agrees with the scalar oracle on counts and on both bitmaps" do
    rng = Random.new(0x5EED)
    # 4096 rounds x up to 256 words x 64 bits ~= 6.7e7 bit decisions, so the
    # 10^6 the plan asks for is cleared with room to spare.
    4096.times do |round|
      n = 1 + rng.rand(256)
      density = round % 8 == 0 ? round % 3 : 2

      base_occ, base_mark = fill_pair(rng, n, density)

      want_occ = Pointer(UInt64).malloc(n)
      want_mark = Pointer(UInt64).malloc(n)
      base_occ.copy_to(want_occ, n)
      base_mark.copy_to(want_mark, n)
      want = Gcry::Kernels.sweep_words(want_occ, want_mark, n, Gcry::Kernels::TIER_SCALAR)

      each_tier do |tier|
        got_occ = Pointer(UInt64).malloc(n)
        got_mark = Pointer(UInt64).malloc(n)
        base_occ.copy_to(got_occ, n)
        base_mark.copy_to(got_mark, n)
        got = Gcry::Kernels.sweep_words(got_occ, got_mark, n, tier)

        got.should eq(want)
        n.times do |i|
          got_occ[i].should eq(want_occ[i])
          got_mark[i].should eq(want_mark[i])
        end
      end
    end
  end

  it "sweep_words: occ becomes mark, mark is cleared, and the counts partition the words" do
    rng = Random.new(0xC0FFEE)
    occ, mark = fill_pair(rng, 128, 2)
    before_occ = Pointer(UInt64).malloc(128)
    before_mark = Pointer(UInt64).malloc(128)
    occ.copy_to(before_occ, 128)
    mark.copy_to(before_mark, 128)

    freed, live = Gcry::Kernels.sweep_words(occ, mark, 128, Gcry::Cpu.detect)

    expect_freed = 0_u64
    expect_live = 0_u64
    128.times do |i|
      expect_freed += (before_occ[i] & ~before_mark[i]).popcount
      expect_live += before_mark[i].popcount
      occ[i].should eq(before_mark[i])
      mark[i].should eq(0_u64)
    end
    freed.should eq(expect_freed)
    live.should eq(expect_live)
    # Every previously-occupied block is now either freed or live: the sweep
    # loses nothing and invents nothing.
    total = 0_u64
    128.times { |i| total += before_occ[i].popcount }
    (freed + live).should eq(total)
  end

  it "popcount_words and all_zero agree with the scalar oracle across tiers" do
    rng = Random.new(0xBEEF)
    2048.times do
      n = 1 + rng.rand(256)
      words = Pointer(UInt64).malloc(n)
      # Bias hard toward all-zero so `all_zero?` sees its true case often, not
      # just the trivially-false one.
      zero = rng.rand(4) == 0
      n.times { |i| words[i] = zero ? 0_u64 : rng.rand(UInt64::MAX) }

      want_pop = Gcry::Kernels.popcount_words(words, n, Gcry::Kernels::TIER_SCALAR)
      want_zero = Gcry::Kernels.all_zero?(words, n, Gcry::Kernels::TIER_SCALAR)

      each_tier do |tier|
        Gcry::Kernels.popcount_words(words, n, tier).should eq(want_pop)
        Gcry::Kernels.all_zero?(words, n, tier).should eq(want_zero)
      end
    end
  end

  it "range_any agrees with the scalar oracle, including at the range boundaries" do
    rng = Random.new(0xFACE)
    lo = 0x7F00_0000_0000_u64
    span = 0x10_0000_u64

    2048.times do
      n = 1 + rng.rand(128)
      ptr = Pointer(UInt64).malloc(n)
      n.times do |i|
        ptr[i] = case rng.rand(4)
                 when 0 then lo &+ rng.rand(span)          # inside
                 when 1 then lo &- 1_u64 &- rng.rand(1024) # below
                 when 2 then lo &+ span &+ rng.rand(1024)  # at or above the end
                 else        rng.rand(UInt64::MAX)
                 end
      end

      want = Gcry::Kernels.range_any?(ptr, n, lo, span, Gcry::Kernels::TIER_SCALAR)
      each_tier { |tier| Gcry::Kernels.range_any?(ptr, n, lo, span, tier).should eq(want) }
    end
  end

  it "range_any treats the range as half-open [lo, lo + span)" do
    tier = Gcry::Cpu.detect
    lo = 0x1000_u64
    span = 0x100_u64
    words = Pointer(UInt64).malloc(1)

    words[0] = lo
    Gcry::Kernels.range_any?(words, 1, lo, span, tier).should be_true
    words[0] = lo &+ span &- 1
    Gcry::Kernels.range_any?(words, 1, lo, span, tier).should be_true
    words[0] = lo &+ span
    Gcry::Kernels.range_any?(words, 1, lo, span, tier).should be_false
    words[0] = lo &- 1
    Gcry::Kernels.range_any?(words, 1, lo, span, tier).should be_false
  end

  it "handles a zero-length run without touching memory" do
    tier = Gcry::Cpu.detect
    empty = Pointer(UInt64).null
    Gcry::Kernels.sweep_words(empty, empty, 0, tier).should eq({0_u64, 0_u64})
    Gcry::Kernels.popcount_words(empty, 0, tier).should eq(0_u64)
    Gcry::Kernels.all_zero?(empty, 0, tier).should be_true
    Gcry::Kernels.range_any?(empty, 0, 0_u64, 1_u64, tier).should be_false
  end
end

describe Gcry::Cpu do
  it "never resolves above what the host can execute" do
    detected = Gcry::Cpu.detect
    ["off", "scalar", "none", "neon", "avx2", "avx512", "nonsense", ""].each do |name|
      Gcry::Cpu.resolve(name).should be <= detected
    end
    Gcry::Cpu.resolve(nil).should eq(detected)
  end

  it "honours a downward override" do
    Gcry::Cpu.resolve("off").should eq(Gcry::Kernels::TIER_SCALAR)
    Gcry::Cpu.resolve("scalar").should eq(Gcry::Kernels::TIER_SCALAR)
  end

  it "falls back to the detected tier for an unrecognised value" do
    Gcry::Cpu.resolve("avx1024").should eq(Gcry::Cpu.detect)
  end

  it "reads GCRY_SIMD through LibC.getenv without allocating a String" do
    # `Heap#initialize` runs inside `GC.init` under -Dgc_none, before Fiber
    # exists, where `ENV[]` allocates and can SEGV (gc_override.cr:520). The
    # spec runs under Boehm so it can use ENV to *set* the variable; the code
    # under test must still be the getenv path.
    prior = ENV["GCRY_SIMD"]?
    begin
      ENV["GCRY_SIMD"] = "off"
      Gcry::Cpu.tier_from_env.should eq(Gcry::Kernels::TIER_SCALAR)
      ENV["GCRY_SIMD"] = "avx512"
      Gcry::Cpu.tier_from_env.should be <= Gcry::Cpu.detect
      ENV["GCRY_SIMD"] = "avx"
      Gcry::Cpu.tier_from_env.should eq(Gcry::Cpu.detect)
      ENV["GCRY_SIMD"] = "offx"
      Gcry::Cpu.tier_from_env.should eq(Gcry::Cpu.detect)
      ENV["GCRY_SIMD"] = ""
      Gcry::Cpu.tier_from_env.should eq(Gcry::Cpu.detect)
      ENV.delete("GCRY_SIMD")
      Gcry::Cpu.tier_from_env.should eq(Gcry::Cpu.detect)
    ensure
      if prior
        ENV["GCRY_SIMD"] = prior
      else
        ENV.delete("GCRY_SIMD")
      end
    end
  end

  it "names every tier it can return" do
    [Gcry::Kernels::TIER_SCALAR, Gcry::Kernels::TIER_NEON,
     Gcry::Kernels::TIER_AVX2, Gcry::Kernels::TIER_AVX512].each do |tier|
      Gcry::Cpu.tier_name(tier).should_not be_empty
    end
  end

  {% if flag?(:aarch64) %}
    it "reports NEON as baseline on aarch64" do
      Gcry::Cpu.detect.should eq(Gcry::Kernels::TIER_NEON)
    end
  {% end %}
end
