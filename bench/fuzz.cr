# Seeded long-running GC fuzzer with deterministic replay.
#
# Usage:
#   ./bin/fuzz --seed=1 --seconds=30                  # run (default)
#   ./bin/fuzz --seed=1 --seconds=30 --log=crash.log   # run + log ops
#   ./bin/fuzz --replay=crash.log                      # replay logged ops
#
# Log format (one op per line):
#   op_code arg1 arg2 ...
#   # comments (seed, seconds, heap config)
#
# Exercises alloc/free/realloc/collect/minor/incremental/finalizers/fibers.

require "../src/gcry"

# ---- argument parsing ----
seed = 1_i64
seconds = 30
log_path = nil
replay_path = nil

i = 0
while i < ARGV.size
  case ARGV[i]
  when /--seed=(\d+)/
    seed = $1.to_i64
  when /--seconds=(\d+)/
    seconds = $1.to_i
  when /--log=(.+)/
    log_path = $1
  when /--replay=(.+)/
    replay_path = $1
  end
  i += 1
end

# ---- replay mode ----
if replay_path
  lines = File.read_lines(replay_path)
  # Parse header: first line starting with # has seed/seconds
  header_seed = seed
  lines.each do |line|
    if line.starts_with?('#') && line.includes?("seed=")
      if m = line.match(/seed=(\d+)/)
        header_seed = m[1].to_i64
      end
      if m = line.match(/seconds=(\d+)/)
        seconds = m[1].to_i
      end
    end
  end

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

  prune = ->{
    live.select! { |p| heap.is_heap_ptr(p) && heap.live?(p) }
  }

  safe_free = ->(ptr : Void*) {
    return unless heap.is_heap_ptr(ptr) && heap.live?(ptr)
    heap.free(ptr)
  }

  lines.each do |line|
    line = line.strip
    next if line.empty? || line.starts_with?('#')

    parts = line.split(/\s+/)
    next if parts.empty?

    op = parts[0].to_i
    case op
    when 0, 1, 2
      size = parts[1].to_i
      # Atomic flag differs per op; we store it. For replay we match the original.
      atomic = parts[2]? == "1"
      ptr = atomic ? heap.malloc_atomic(size) : heap.malloc(size)
      live << ptr
      if parts[3]? == "1"
        heap.add_finalizer(ptr, callback)
      end
    when 3
      idx = parts[1].to_i
      safe_free.call(live.delete_at(idx)) if idx >= 0 && idx < live.size
    when 4
      idx = parts[1].to_i
      new_size = parts[2].to_i
      if idx >= 0 && idx < live.size
        ptr = live[idx]
        if heap.is_heap_ptr(ptr) && heap.live?(ptr)
          begin
            live[idx] = heap.realloc(ptr, new_size)
          rescue ArgumentError
            live.delete_at(idx)
          end
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
      work = parts[1]?.try(&.to_i) || 256
      finished = heap.collect_a_little(work)
      collects += 1
      prune.call if finished
    when 8
      child = heap.malloc(32)
      parent = heap.malloc(16)
      parent.as(Void**).value = child
      live << parent
      live << child
    when 9
      # spawn/channel is non-deterministic (Crystal runtime, not gcry heap)
      # so it's not logged and skipped during replay; replay no-op.
      limit = parts[1]?.try(&.to_i) || 200
      live.shift if live.size > limit
    when 11
      heap.trim_large_cache(0)
      prune.call
    end
    ops += 1
  end

  prune.call
  heap.collect(scan_stack: false, roots: live)
  prune.call
  live.each { |p| safe_free.call(p) }
  heap.trim_large_cache(0)

  puts "fuzz replay ok seed=#{header_seed} ops=#{ops} collects=#{collects} finalized=#{finalized.get} live_objects=#{heap.live_objects}"
  heap.destroy
  exit 0
end

# ---- fuzz mode ----
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

prune = ->{
  live.select! { |p| heap.is_heap_ptr(p) && heap.live?(p) }
}

safe_free = ->(ptr : Void*) {
  return unless heap.is_heap_ptr(ptr) && heap.live?(ptr)
  heap.free(ptr)
}

log_file = log_path ? File.open(log_path, "w") : nil
if log_file
  log_file.puts "# fuzz log seed=#{seed} seconds=#{seconds}"
  log_file.flush
end

begin
  while Time.instant < deadline
    op = rng.rand(0..11)
    case op
    when 0, 1, 2
      size = rng.rand(1..16_000)
      atomic = rng.next_bool
      ptr = atomic ? heap.malloc_atomic(size) : heap.malloc(size)
      live << ptr
      has_finalizer = rng.rand(0..20) == 0
      if has_finalizer
        heap.add_finalizer(ptr, callback)
      end
      log_file.puts("#{op} #{size} #{atomic ? 1 : 0} #{has_finalizer ? 1 : 0}") if log_file
    when 3
      unless live.empty?
        idx = rng.rand(live.size)
        safe_free.call(live.delete_at(idx))
        log_file.puts("#{op} #{idx}") if log_file
      end
    when 4
      unless live.empty?
        idx = rng.rand(live.size)
        ptr = live[idx]
        if heap.is_heap_ptr(ptr) && heap.live?(ptr)
          new_size = rng.rand(1..20_000)
          begin
            live[idx] = heap.realloc(ptr, new_size)
            log_file.puts("#{op} #{idx} #{new_size}") if log_file
          rescue ArgumentError
            live.delete_at(idx)
          end
        end
      end
    when 5
      roots = live.select { |p| heap.live?(p) }.sample([live.size, 8].min)
      heap.collect(scan_stack: false, roots: roots)
      collects += 1
      prune.call
      log_file.puts("#{op}") if log_file
    when 6
      if heap.nursery_enabled
        roots = live.select { |p| heap.live?(p) }.sample([live.size, 4].min)
        heap.minor_collect(scan_stack: false, roots: roots)
        collects += 1
        prune.call
        log_file.puts("#{op}") if log_file
      end
    when 7
      work = rng.rand(64..512)
      finished = heap.collect_a_little(work)
      collects += 1
      prune.call if finished
      log_file.puts("#{op} #{work}") if log_file
    when 8
      child = heap.malloc(32)
      parent = heap.malloc(16)
      parent.as(Void**).value = child
      live << parent
      live << child
      log_file.puts("#{op}") if log_file
    when 9
      ch = Channel(Nil).new
      spawn { ch.send(nil) }
      ch.receive
      # op 9 is non-deterministic (Fiber/Channel — Crystal runtime, not gcry heap)
      # so we skip logging it; replay skips unlogged ops.
    when 10
      live.shift if live.size > 200
      log_file.puts("#{op} 200") if log_file
    when 11
      heap.trim_large_cache(0) if rng.next_bool
      prune.call
      log_file.puts("#{op}") if log_file
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
  log_file.try(&.close)
  heap.destroy
end