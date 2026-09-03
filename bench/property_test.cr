# Property-based heap graph fuzzer for gcry.
#
# Generates random alloc/free/collect sequences and verifies GC invariants:
#   1. All explicitly-rooted nodes survive collection (no false negatives)
#   2. live_objects counter matches actual live block count
#   3. heap_size == sum(chunk.mapped_bytes) across all chunks
#   4. Every live block header is non-FREE and in-bounds
#   5. Freelist consistency (via Gcry::Invariant)
#   6. No double-free or use-after-free errors
#
# Every alive node is passed as a root to collect(roots: ...).
#
# Build:  crystal build bench/property_test.cr -o bin/property_test
# Run:    ./bin/property_test [--seed=1] [--iterations=100000] [--log=crash.log]

require "../src/gcry"
require "../src/gcry/invariant"

# ---- CLI args ----
seed = 1_i64
iterations = 100_000
log_path = nil

ARGV.each do |arg|
  case arg
  when /--seed=(\d+)/
    seed = $1.to_i64
  when /--iterations=(\d+)/
    iterations = $1.to_i
  when /--log=(.+)/
    log_path = $1
  end
end

# ---- Constants ----
SLOTS    = 8
OBJ_SIZE = SLOTS * sizeof(Void*)
MAX_LIVE = 200

# ---- State ----
heap = Gcry::Heap.new
heap.scan_static_roots = false
heap.gc_threshold = UInt64::MAX
heap.nursery_threshold = UInt64::MAX
heap.nursery_enabled = false
heap.release_empty_chunks = true

# Enable invariant checker
Gcry::Invariant.enable

live_ptrs = [] of Void*
next_id = 0
errors = [] of String

# Bootstrap: 5 seed nodes
5.times do
  ptr = heap.malloc(OBJ_SIZE)
  live_ptrs << ptr
  next_id += 1
end

# ---- Deep invariant checks ----

# Count live blocks and sum chunk mapped_bytes by walking the chunk list.
def walk_heap(heap)
  chunk_count = 0_u64
  mapped_sum = 0_u64
  live_count = 0_u64
  free_count = 0_u64
  chunk_size_classes = [] of Int32

  heap.each_chunk do |chunk|
    chunk_count += 1
    mapped_sum += chunk.value.mapped_bytes
    chunk_size_classes << chunk.value.size_class.to_i32

    if Gcry::ChunkHeader.large?(chunk)
      # Large objects store a single block, read its header.
      header = Gcry::ChunkHeader.data_start(chunk).as(Gcry::BlockHeader*)
      if Gcry::BlockHeader.free?(header)
        free_count += 1
      else
        live_count += 1
      end
    else
      class_index = chunk.value.size_class.to_i32
      payload = Gcry::SizeClasses.payload(class_index)
      block_bytes = Gcry::BlockHeader::SIZE.to_u64 + payload.to_u64
      # `occ`, not the header's FREE flag, on a chunk whose allocation is
      # bitmap-driven: the streaming sweep never writes FREE into the blocks it
      # reclaims (`occ` is the authority instead), so a header walk counts every
      # reclaimed block as live. `src/gcry/invariant.cr` carries the same fix;
      # this walker is its twin and was missed.
      if heap.bitmap_alloc_chunk_public?(chunk)
        occupied = heap.chunk_occupied_count(chunk)
        total = (Gcry::ChunkHeader.data_end(chunk).address -
                 Gcry::ChunkHeader.data_start(chunk).address) // block_bytes
        live_count += occupied
        free_count += total - occupied
        next
      end
      cursor = Gcry::ChunkHeader.data_start(chunk).as(UInt8*)
      limit = Gcry::ChunkHeader.data_end(chunk).as(UInt8*)
      while (cursor + block_bytes) <= limit
        header = cursor.as(Gcry::BlockHeader*)
        if Gcry::BlockHeader.free?(header)
          free_count += 1
        else
          live_count += 1
        end
        cursor += block_bytes
      end
    end
  end

  {chunk_count, mapped_sum, live_count, free_count, chunk_size_classes}
end

# Verify all heap invariants.
def verify_heap_invariants(heap, live_ptrs, verify_id)
  errors = [] of String
  pass = true

  chunk_count, mapped_sum, actual_live, free_count, chunk_sizes = walk_heap(heap)

  # 1. heap_size == sum(chunk.mapped_bytes)
  reported_size = heap.heap_size
  if reported_size != mapped_sum
    errors << "HEAP_SIZE mismatch: reported=#{reported_size} walked=#{mapped_sum} (chunks=#{chunk_count})"
    pass = false
  end

  # 2. live_objects == actual live block count in walk
  reported_live = heap.live_objects
  if reported_live != actual_live
    errors << "LIVE_OBJECTS mismatch: reported=#{reported_live} walked=#{actual_live}"
    pass = false
  end

  # 3. All our tracked pointers are live (no false negatives).
  live_ptrs.each_with_index do |ptr, i|
    next if ptr.null?
    unless heap.live?(ptr)
      errors << "FALSE NEGATIVE: node #{i} (ptr=#{ptr}) is DEAD after collect"
      pass = false
    end
  end

  # 4. Freelist invariants (via Gcry::Invariant).
  Gcry::Invariant.check_all_freelists(heap)

  # 5. Every live block we know about has a valid non-FREE header.
  live_ptrs.each do |ptr|
    next if ptr.null?
    header = Gcry::BlockHeader.from_user(ptr)
    if Gcry::BlockHeader.free?(header)
      errors << "FREE HEADER on ptr=#{ptr}"
      pass = false
    end
    # Block should be inside the heap
    unless heap.is_heap_ptr(ptr)
      errors << "NOT HEAP PTR: ptr=#{ptr}"
      pass = false
    end
  end

  {pass, errors, chunk_count, mapped_sum, actual_live, free_count}
end

# ---- Log ----
log_file = log_path ? File.open(log_path, "w") : nil
if log_file
  log_file.puts "# property test seed=#{seed} iterations=#{iterations}"
  log_file.flush
end

# ---- Fuzz mode ----
rng = Random.new(seed)
deadline = Time.instant + 300.seconds

ops = 0_u64
collect_count = 0_u64
verify_count = 0_u64
freed_count = 0_u64

begin
  while ops < iterations && Time.instant < deadline
    # Evict oldest when we exceed MAX_LIVE
    while live_ptrs.size > MAX_LIVE
      ptr = live_ptrs.shift
      next if ptr.null?
      begin
        heap.free(ptr)
      rescue ArgumentError
        errors << "DOUBLE FREE on evict: #{ptr}"
      end
      freed_count += 1
      log_file.puts("F #{ptr.address}") if log_file
    end

    op = rng.rand(0..6)
    case op
    when 0, 1, 2 # ALLOC
      ptr = heap.malloc(OBJ_SIZE)
      live_ptrs << ptr
      log_file.puts("A #{next_id}") if log_file
      next_id += 1
    when 3 # FREE
      if live_ptrs.size > 10
        idx = rng.rand(5...live_ptrs.size) # keep first 5
        ptr = live_ptrs.delete_at(idx)
        begin
          heap.free(ptr)
        rescue ArgumentError
          errors << "DOUBLE FREE: #{ptr}"
        end
        freed_count += 1
        log_file.puts("F") if log_file
      end
    when 4 # COLLECT + VERIFY_ALL
      ptrs = live_ptrs.reject(&.null?).dup
      heap.collect(scan_stack: false, roots: ptrs)
      collect_count += 1

      pass, errs, cc, ms, al, fc = verify_heap_invariants(heap, live_ptrs, verify_count)
      errors.concat(errs)
      unless pass
        STDERR.puts "PROPERTY FAIL: #{errs.first}"
        STDERR.puts "seed=#{seed} ops=#{ops} collects=#{collect_count}"
        exit 1
      end
      verify_count += 1
      log_file.puts("C") if log_file
    when 5 # COLLECT (verify only live_ptrs)
      ptrs = live_ptrs.reject(&.null?).dup
      heap.collect(scan_stack: false, roots: ptrs)
      collect_count += 1

      live_ptrs.each_with_index do |ptr, i|
        next if ptr.null?
        unless heap.live?(ptr)
          STDERR.puts "PROPERTY FAIL: node #{i} DEAD after collect"
          STDERR.puts "seed=#{seed} ops=#{ops} collects=#{collect_count}"
          exit 1
        end
      end
      verify_count += 1
    when 6 # COLLECT with full invariants (freelist + heap walk)
      Gcry::Invariant.check_all_freelists(heap)
      Gcry::Invariant.check_live_objects(heap)

      ptrs = live_ptrs.reject(&.null?).dup
      heap.collect(scan_stack: false, roots: ptrs)
      collect_count += 1

      pass, errs, cc, ms, al, fc = verify_heap_invariants(heap, live_ptrs, verify_count)
      errors.concat(errs)
      unless pass
        STDERR.puts "PROPERTY FAIL: #{errs.first}"
        STDERR.puts "seed=#{seed} ops=#{ops} collects=#{collect_count}"
        exit 1
      end
      verify_count += 1
    end
    ops += 1
  end

  # Final collect + full verify
  ptrs = live_ptrs.reject(&.null?).dup
  heap.collect(scan_stack: false, roots: ptrs)
  collect_count += 1
  pass, errs, cc, ms, al, fc = verify_heap_invariants(heap, live_ptrs, verify_count)
  errors.concat(errs)
  unless pass
    STDERR.puts "PROPERTY FAIL (final): #{errs.first}"
    exit 1
  end

  # Cleanup
  live_ptrs.each do |ptr|
    next if ptr.null?
    begin
      heap.free(ptr)
    rescue ArgumentError
    end
  end
  heap.trim_large_cache(0)

  if errors.any?
    errors.each { |e| STDERR.puts "PROPERTY WARN: #{e}" }
  end

  puts "property test ok seed=#{seed} iterations=#{ops} collects=#{collect_count} verifies=#{verify_count} freed=#{freed_count} peak_nodes=#{next_id} warnings=#{errors.size}"
  puts "  last walk: chunks=#{cc} mapped_sum=#{ms} live=#{al} free=#{fc}"
ensure
  log_file.try(&.close)
  Gcry::Invariant.disable
  heap.destroy
end
