require "../../../../src/gcry"

class Gcry::Heap
  def bench_resolve(ptrs : Array(Void*)) : UInt64
    acc = 0_u64
    ptrs.each do |p|
      chunk = chunk_containing_unlocked(p.address)
      next unless chunk
      acc &+= chunk.address
    end
    acc
  end

  def bench_find(ptrs : Array(Void*)) : UInt64
    acc = 0_u64
    ptrs.each do |p|
      if f = find_block_with_chunk(p)
        acc &+= f[0].address
        acc &+= 1 if block_allocated?(f[1], f[0])
      end
    end
    acc
  end

  def bench_find_only(ptrs : Array(Void*)) : UInt64
    acc = 0_u64
    ptrs.each do |p|
      if f = find_block_with_chunk(p)
        acc &+= f[0].address
      end
    end
    acc
  end

  def bench_find_occ_mark(ptrs : Array(Void*)) : UInt64
    acc = 0_u64
    ptrs.each do |p|
      if f = find_block_with_chunk(p)
        acc &+= 1 if block_allocated?(f[1], f[0])
        acc &+= 1 if block_marked_in?(f[1], f[0])
      end
    end
    acc
  end

  # The mark word read from the occupancy word's own line: what an
  # interleaved occ/mark layout would cost.
  def bench_find_occ_sameline(ptrs : Array(Void*)) : UInt64
    acc = 0_u64
    ptrs.each do |p|
      if f = find_block_with_chunk(p)
        acc &+= 1 if block_allocated?(f[1], f[0])
        acc &+= 1 if block_allocated?(f[1], f[0].as(UInt8*).+(16).as(BlockHeader*))
      end
    end
    acc
  end

  def bench_world_stopped(v : Bool) : Nil
    @world_stopped = v
  end

  def bench_touch(ptrs : Array(Void*)) : UInt64
    acc = 0_u64
    ptrs.each { |p| acc &+= p.as(UInt64*).value }
    acc
  end
end

n = (ARGV[0]? || "1000000").to_i
heap = Gcry::Heap.new
heap.gc_threshold = UInt64::MAX
ptrs = Array(Void*).new(n * 3)
n.times do
  ptrs << heap.malloc(48)
  ptrs << heap.malloc(80)
  ptrs << heap.malloc(64)
end
heap.bench_world_stopped(true) if ENV["STOPPED"]?
{"sequential" => ptrs.dup, "random" => ptrs.shuffle(Random.new(7))}.each do |name, list|
  {"touch" => -> { heap.bench_touch(list) }, "radix" => -> { heap.bench_resolve(list) }, "find" => -> { heap.bench_find_only(list) }, "find+occ" => -> { heap.bench_find(list) }, "find+occ+mark" => -> { heap.bench_find_occ_mark(list) }, "find+occ+sameline" => -> { heap.bench_find_occ_sameline(list) }}.each do |what, fn|
    fn.call
    t0 = Time.instant
    3.times { fn.call }
    ns = (Time.instant - t0).total_nanoseconds / 3 / list.size
    puts "#{name} #{what}: #{ns.round(1)} ns/ptr"
  end
end
