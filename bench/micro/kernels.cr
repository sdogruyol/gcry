# Microbenchmark for the SIMD bitmap kernels.
#
# This is the Phase 0 floor: what the sweep kernel costs per byte of bitmap
# before any of it is wired into the collector, so that when Phase 3's
# `phase_sweep` number arrives there is something to attribute it to. Pure
# kernel bench — no heap, no collector, nothing allocated in a timed region.
#
# The bar the plan sets is **sweep >= 20 GB/s of bitmap on AVX2**. At one bit
# per block and a 128 KiB chunk that is 512 B of `occ` plus 512 B of `mark` per
# chunk, so 20 GB/s is ~20 million chunks a second — a 1 GiB heap's sweep
# reduced to a few hundred microseconds of bitmap traffic.
#
# ## How this avoids measuring nothing
#
# The first cut of this file reported 1800 GB/s for `popcount_words`, which is
# roughly 200 words per nanosecond and therefore not a measurement. Three
# things were wrong, and the structure below exists to prevent each:
#
#  1. **LICM.** Calling a pure kernel on the *same* pointers every iteration
#     makes it loop-invariant, so LLVM hoists it out of the timing loop and the
#     loop times nothing. Fixed by walking an arena: every call in a pass gets
#     different pointers, exactly as the real sweep walks different chunks.
#  2. **DCE.** A result nobody reads is a call nobody makes. Fixed by folding
#     every result into `SINK`, a store to escaped memory that LLVM cannot
#     prove dead, printed at the end so it cannot be constant-folded either.
#  3. **Setup domination.** `sweep_words` consumes its input — it writes
#     `occ = mark` and zeroes `mark` — so a second pass over the same bitmap is
#     a *different* workload (all-dead) and a third is all-zero. The restore is
#     a memcpy of exactly the bytes the kernel streams, so timing it alongside
#     halves the answer. Fixed by stopping the clock across the reseed and
#     summing only the timed spans, rather than subtracting an estimate.
#
# The arena is walked in per-chunk slices because that is the real call shape:
# the collector calls these kernels once per chunk, not once per heap.
#
# Usage:
#   crystal build --release bench/micro/kernels.cr -o bin/kernels_micro
#   ./bin/kernels_micro [--passes=N]
#
# Output: JSON lines to stdout.

require "../../src/gcry/cpu"

# One class-0 chunk's bitmap: a 128 KiB chunk of 32-byte blocks holds ~4063
# blocks, so 64 words of 64 bits. This is the smallest and most frequent call
# the collector will make, and the one where per-call overhead shows up.
CHUNK_WORDS = 64

# Working sets. "l2" keeps both arrays resident so the reading is the
# instruction-cost floor; "dram" is past any L3 on this class of host, which is
# what sweep actually sees on a large heap — and where the kernel is
# bandwidth-bound and the vector width stops mattering. `simdgc-perf-notes.md`
# measured that same flattening, which is why AVX-512 is expected to be worth
# ~1.3x on sweep rather than 2x.
L2_WORDS   =   32768 #  256 KiB per array
DRAM_WORDS = 8388608 #   64 MiB per array

SINK = Pointer(UInt64).malloc(1)

def now_ns : UInt64
  ts = uninitialized LibC::Timespec
  LibC.clock_gettime(LibC::CLOCK_MONOTONIC, pointerof(ts))
  ts.tv_sec.to_u64 &* 1_000_000_000_u64 &+ ts.tv_nsec.to_u64
end

def json_line(fields : Hash(String, String)) : Nil
  parts = fields.map { |k, v| "\"#{k}\":#{v}" }
  puts "{#{parts.join(",")}}"
end

def fill(words : Int32, seed : UInt64) : Pointer(UInt64)
  ptr = Pointer(UInt64).malloc(words)
  state = seed
  words.times do |i|
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    ptr[i] = state
  end
  ptr
end

def report(label : String, tier : UInt8, words : Int32, passes : Int32,
           arrays : Int32, ns : UInt64) : Nil
  bytes = words.to_f * 8.0 * arrays.to_f * passes.to_f
  gbps = bytes / (ns.to_f / 1_000_000_000.0) / 1_000_000_000.0
  json_line({
    "bench"       => "\"#{label}\"",
    "tier"        => "\"#{Gcry::Cpu.tier_name(tier)}\"",
    "words"       => words.to_s,
    "passes"      => passes.to_s,
    "gb_per_s"    => gbps.round(2).to_s,
    "ns_per_word" => (ns.to_f / (words.to_f * passes.to_f)).round(4).to_s,
  })
end

passes = 8
ARGV.each do |arg|
  passes = arg.split("=", 2)[1].to_i if arg.starts_with?("--passes=")
end

detected = Gcry::Cpu.detect
json_line({"host_tier" => "\"#{Gcry::Cpu.tier_name(detected)}\"", "passes" => passes.to_s})

# Only tiers this build actually has clones for. On x86_64 the NEON tier
# dispatches to the scalar clone, so measuring it would print the scalar number
# twice under two names — the kind of duplicate a reader would later mistake for
# evidence that NEON was tested here.
tiers = [Gcry::Kernels::TIER_SCALAR]
{% if flag?(:x86_64) %}
  tiers << Gcry::Kernels::TIER_AVX2 if detected >= Gcry::Kernels::TIER_AVX2
  tiers << Gcry::Kernels::TIER_AVX512 if detected >= Gcry::Kernels::TIER_AVX512
{% elsif flag?(:aarch64) %}
  tiers = [Gcry::Kernels::TIER_NEON]
{% end %}

{ {"l2", L2_WORDS}, {"dram", DRAM_WORDS} }.each do |(where, words)|
  chunks = words // CHUNK_WORDS

  occ = fill(words, 0x9E3779B97F4A7C15_u64)
  mark = fill(words, 0xD1B54A32D192ED03_u64)
  # `mark` must be a subset of `occ`: the collector cannot mark a block it never
  # allocated, and `occ & ~mark` is only meaningful under that relation.
  words.times { |i| mark[i] &= occ[i] }

  seed_occ = Pointer(UInt64).malloc(words)
  seed_mark = Pointer(UInt64).malloc(words)
  occ.copy_to(seed_occ, words)
  mark.copy_to(seed_mark, words)

  tiers.each do |tier|
    # ---- sweep_words: mutating, so the clock stops across each reseed ----
    sink = 0_u64
    2.times do # warm
      seed_occ.copy_to(occ, words)
      seed_mark.copy_to(mark, words)
      chunks.times { |c| Gcry::Kernels.sweep_words(occ + c * CHUNK_WORDS, mark + c * CHUNK_WORDS, CHUNK_WORDS, tier) }
    end

    total = 0_u64
    passes.times do
      seed_occ.copy_to(occ, words)
      seed_mark.copy_to(mark, words)
      t0 = now_ns
      chunks.times do |c|
        freed, live = Gcry::Kernels.sweep_words(occ + c * CHUNK_WORDS, mark + c * CHUNK_WORDS, CHUNK_WORDS, tier)
        sink &+= freed &+ live
      end
      total &+= now_ns &- t0
    end
    SINK[0] ^= sink
    report("sweep_words/#{where}", tier, words, passes, 2, total)

    # ---- read-only kernels: no reseed, but still walked per chunk ----
    sink = 0_u64
    2.times { chunks.times { |c| sink &+= Gcry::Kernels.popcount_words(seed_occ + c * CHUNK_WORDS, CHUNK_WORDS, tier) } }
    total = 0_u64
    passes.times do
      t0 = now_ns
      chunks.times { |c| sink &+= Gcry::Kernels.popcount_words(seed_occ + c * CHUNK_WORDS, CHUNK_WORDS, tier) }
      total &+= now_ns &- t0
    end
    SINK[0] ^= sink
    report("popcount_words/#{where}", tier, words, passes, 1, total)

    sink = 0_u64
    2.times { chunks.times { |c| sink &+= Gcry::Kernels.all_zero?(seed_occ + c * CHUNK_WORDS, CHUNK_WORDS, tier) ? 1_u64 : 0_u64 } }
    total = 0_u64
    passes.times do
      t0 = now_ns
      chunks.times { |c| sink &+= Gcry::Kernels.all_zero?(seed_occ + c * CHUNK_WORDS, CHUNK_WORDS, tier) ? 1_u64 : 0_u64 }
      total &+= now_ns &- t0
    end
    SINK[0] ^= sink
    report("all_zero/#{where}", tier, words, passes, 1, total)

    # A range at the bottom of the address space misses every word of a random
    # bitmap. That is the shape a stack scan sees — most words are not heap
    # pointers — and the filter's whole value is how fast it says "none of
    # these". The hit case is deliberately not measured here: it degenerates to
    # the scalar path by design, and its cost belongs to Phase 4's A/B.
    sink = 0_u64
    2.times { chunks.times { |c| sink &+= Gcry::Kernels.range_any?(seed_occ + c * CHUNK_WORDS, CHUNK_WORDS, 0_u64, 4096_u64, tier) ? 1_u64 : 0_u64 } }
    total = 0_u64
    passes.times do
      t0 = now_ns
      chunks.times { |c| sink &+= Gcry::Kernels.range_any?(seed_occ + c * CHUNK_WORDS, CHUNK_WORDS, 0_u64, 4096_u64, tier) ? 1_u64 : 0_u64 }
      total &+= now_ns &- t0
    end
    SINK[0] ^= sink
    report("range_any_miss/#{where}", tier, words, passes, 1, total)
  end
end

# Printed so nothing above can be folded away as dead. The value is not
# meaningful; its observability is.
json_line({"sink" => SINK[0].to_s})
