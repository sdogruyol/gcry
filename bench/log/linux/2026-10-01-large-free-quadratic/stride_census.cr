require "../../../../src/gcry"

module Distributions
  # Zipfian (power-law) — many small, few large.
  def self.zipfian(rng : Random, count : Int32, min_size : Int32 = 8, max_size : Int32 = 65536, alpha : Float64 = 1.0) : Array(Int32)
    n = 1000
    weights = Array.new(n) { |i| 1.0 / ((i + 1) ** alpha) }
    total = weights.sum
    cdf = Array.new(n) { |i| weights[0..i].sum / total }

    sizes = Array(Int32).new(count)
    count.times do
      r = rng.rand
      idx = cdf.index { |v| v >= r } || (n - 1)
      t = idx.to_f / n
      sizes << (min_size + (max_size - min_size) * t).to_i32
    end
    sizes
  end

  # Bimodal — cluster of small allocs, cluster of large allocs.
  def self.bimodal(rng : Random, count : Int32, small_size : Int32 = 16, large_size : Int32 = 32768, large_ratio : Float64 = 0.1) : Array(Int32)
    sizes = Array(Int32).new(count)
    count.times do
      if rng.rand < large_ratio
        sizes << (large_size * (0.5 + rng.rand)).to_i32
      else
        sizes << (small_size * (1.0 + rng.rand * 3)).to_i32
      end
    end
    sizes
  end

  # Stride — growing allocations like array resize (doubling pattern with noise).
  def self.stride(rng : Random, count : Int32, min_size : Int32 = 8, max_size : Int32 = 131072) : Array(Int32)
    sizes = Array(Int32).new(count)
    sz = min_size
    count.times do
      sizes << (sz * (0.8 + rng.rand * 0.4)).to_i32
      if sz < max_size / 4
        sz = (sz * 1.5).to_i32
      elsif rng.rand < 0.3
        sz = [(sz * 2).to_i32, max_size].min
      end
    end
    sizes
  end
end

def census_and_exit(heap : Gcry::Heap, phase : Int32) : NoReturn
  on_list = Set(UInt64).new
  list_bytes = 0_u64
  list_entries = 0
  Gcry::Heap::LARGE_FREE_BUCKETS.times do |b|
    u = heap.@large_freelists[b]
    steps = 0
    while !u.null? && steps < 2_000_000
      on_list << u.address
      h = Gcry::BlockHeader.large_header_from_user(u)
      c = (h.as(UInt8*) - Gcry::ChunkHeader::SIZE).as(Gcry::ChunkHeader*)
      list_bytes &+= c.value.mapped_bytes
      list_entries += 1
      u = h.value.next_free
      steps += 1
    end
  end
  small = 0; large_free_on = 0; large_free_off = 0; large_used = 0; large_zero = 0
  i = 0
  while i < heap.@chunk_index_count
    c = heap.@chunk_index[i]
    if Gcry::ChunkHeader.large?(c)
      h = Gcry::ChunkHeader.large_header(c)
      user = Gcry::BlockHeader.large_user_from_header(h)
      if h.value.size == 0
        large_zero += 1
      elsif Gcry::BlockHeader.free_large?(h)
        on_list.includes?(user.address) ? (large_free_on += 1) : (large_free_off += 1)
      else
        large_used += 1
      end
    else
      small += 1
    end
    i += 1
  end
  STDERR.puts "CENSUS phase=#{phase} index=#{heap.@chunk_index_count} small=#{small} large_free_on_list=#{large_free_on} " \
              "large_free_off_list=#{large_free_off} large_used=#{large_used} large_size0=#{large_zero} " \
              "list_entries=#{list_entries} list_bytes=#{list_bytes >> 20}MiB counter=#{heap.@large_free_bytes >> 20}MiB " \
              "twice=#{heap.large_cached_twice} taken_used=#{heap.large_taken_used} " \
              "by_sweep=#{heap.@large_cached_by_sweep} by_free=#{heap.@large_cached_by_free} pending=#{!heap.@pending_large_cache.null?}"
  # Who holds the retained `live` buffers? The stride blocks are atomic, the
  # buffers that point at them are not: search every non-atomic USED large.
  j = 0
  bufs = 0
  while j < heap.@chunk_index_count && bufs < 8
    c = heap.@chunk_index[j]
    if Gcry::ChunkHeader.large?(c)
      h = Gcry::ChunkHeader.large_header(c)
      user = Gcry::BlockHeader.large_user_from_header(h)
      first = user.as(UInt64*).value
      if !Gcry::BlockHeader.free_large?(h) && h.value.size > 0 && first >= heap.@heap_min && first < heap.@heap_max
        STDERR.puts "HOLDERS of buffer 0x#{user.address.to_s(16)} size=#{h.value.size}"
        Gcry::PoisonHolders.search(heap, user.address, h.value.size.to_u64)
        bufs += 1
      end
    end
    j += 1
  end
  STDERR.puts "BUFFERS searched=#{bufs}"
  exit 3
end

seed = (ARGV.find(&.starts_with?("--seed=")).try(&.split('=')[1].to_i) || 1)
phases = (ARGV.find(&.starts_with?("--phases=")).try(&.split('=')[1].to_i) || 200)
per = 5000
rng = Random.new(seed)
heap = Gcry.default_heap.not_nil!
t0 = Time.instant
phases.times do |i|
  if i % 50 == 0
    STDERR.puts "phase #{i} elapsed=#{(Time.instant - t0).total_seconds.round(1)}s heap=#{heap.heap_size >> 20}MiB mapped=#{heap.chunks_mapped} unmapped=#{heap.unmapped_bytes >> 20}MiB index=#{heap.@chunk_index_count}"
  end
  sizes = Distributions.stride(rng, per)
  live = [] of Pointer(Void)
  sizes.each { |sz| live << GC.malloc_atomic(sz) }
  live.each_with_index { |ptr, j| GC.free(ptr) if j.even? }
  live = [] of Pointer(Void)
  GC.collect
  census_and_exit(heap, i) if heap.@chunk_index_count > 8000
end
puts "stride ok seed=#{seed} twice=#{heap.large_cached_twice} taken_used=#{heap.large_taken_used}"
