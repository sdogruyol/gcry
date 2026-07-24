# Seeded long-running GC fuzzer (library heap under Boehm by default).
# Build: crystal build bench/fuzz.cr -o bin/fuzz
# Run:   ./bin/fuzz [seconds=30] [seed=1]
#
# Exercises alloc/free/realloc/collect/minor/incremental/finalizers/fibers.

require "../src/gcry"

seconds = (ARGV[0]? || "30").to_i
seed = (ARGV[1]? || "1").to_i64
deadline = Time.instant + seconds.seconds
rng = Random.new(seed)

heap = Gcry::Heap.new
heap.scan_static_roots = false
heap.gc_threshold = UInt64::MAX
heap.nursery_threshold = UInt64::MAX
heap.nursery_enabled = true
heap.release_empty_chunks = true

ops = 0_u64
collects = 0_u64
live = [] of Void*
finalized = Atomic(Int32).new(0)

callback = ->(_obj : Void*) { finalized.add(1) }

prune = -> {
  live.select! { |p| heap.is_heap_ptr(p) && heap.live?(p) }
}

safe_free = ->(ptr : Void*) {
  return unless heap.is_heap_ptr(ptr) && heap.live?(ptr)
  heap.free(ptr)
}

begin
  while Time.instant < deadline
    op = rng.rand(0..11)
    case op
    when 0, 1, 2
      size = rng.rand(1..16_000)
      ptr = rng.next_bool ? heap.malloc(size) : heap.malloc_atomic(size)
      live << ptr
      if rng.rand(0..20) == 0
        heap.add_finalizer(ptr, callback)
      end
    when 3
      unless live.empty?
        idx = rng.rand(live.size)
        safe_free.call(live.delete_at(idx))
      end
    when 4
      unless live.empty?
        idx = rng.rand(live.size)
        ptr = live[idx]
        next unless heap.is_heap_ptr(ptr) && heap.live?(ptr)
        new_size = rng.rand(1..20_000)
        begin
          live[idx] = heap.realloc(ptr, new_size)
        rescue ArgumentError
          live.delete_at(idx)
        end
      end
    when 5
      roots = live.select { |p| heap.live?(p) }.sample([live.size, 8].min)
      heap.collect(scan_stack: false, roots: roots)
      collects += 1
      prune.call
    when 6
      if heap.nursery_enabled
        roots = live.select { |p| heap.live?(p) }.sample([live.size, 4].min)
        heap.minor_collect(scan_stack: false, roots: roots)
        collects += 1
        prune.call
      end
    when 7
      finished = heap.collect_a_little(rng.rand(64..512))
      collects += 1
      prune.call if finished
    when 8
      child = heap.malloc(32)
      parent = heap.malloc(16)
      parent.as(Void**).value = child
      live << parent
      live << child
    when 9
      ch = Channel(Nil).new
      spawn { ch.send(nil) }
      ch.receive
    when 10
      live.shift if live.size > 200
    when 11
      heap.trim_large_cache(0) if rng.next_bool
      prune.call
    end
    ops += 1

    while live.size > 400
      safe_free.call(live.shift)
    end
  end

  prune.call
  heap.collect(scan_stack: false, roots: live)
  prune.call
  live.each { |p| safe_free.call(p) }
  heap.trim_large_cache(0)

  puts "fuzz ok seed=#{seed} seconds=#{seconds} ops=#{ops} collects=#{collects} finalized=#{finalized.get} live_objects=#{heap.live_objects}"
ensure
  heap.destroy
end
