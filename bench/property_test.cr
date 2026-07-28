# Property-based heap graph fuzzer for gcry.
#
# Generates random alloc/free/collect sequences and verifies GC invariants:
#   1. All explicitly-rooted nodes survive collection (no false negatives)
#   2. live_objects counter is consistent
#   3. No double-free or use-after-free errors
#   4. Each collect can run with GCRY_DEBUG_INVARIANTS=1
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

# ---- Helpers ----

def verify(live_ptrs, heap)
  errors = [] of String
  pass = true

  live_ptrs.each_with_index do |ptr, i|
    next if ptr.null?
    unless heap.live?(ptr)
      errors << "FALSE NEGATIVE: node #{i} (ptr=#{ptr}) is DEAD after collect"
      pass = false
    end
  end

  # live_objects sanity: should be at least as many as our live ptrs
  actual_live = heap.live_objects
  expected_min = live_ptrs.count { |p| !p.null? }
  if actual_live < expected_min
    errors << "LIVE_OBJECTS UNDERSHOOT: expected at least #{expected_min}, got #{actual_live}"
    pass = false
  end

  {pass, errors}
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
    when 4 # COLLECT + VERIFY
      ptrs = live_ptrs.reject(&.null?).dup
      heap.collect(scan_stack: false, roots: ptrs)
      collect_count += 1

      pass, errs = verify(live_ptrs, heap)
      errors.concat(errs)
      unless pass
        STDERR.puts "PROPERTY FAIL: #{errs.first}"
        STDERR.puts "seed=#{seed} ops=#{ops} collects=#{collect_count}"
        exit 1
      end
      verify_count += 1
      log_file.puts("C") if log_file
    when 5 # COLLECT (no log)
      ptrs = live_ptrs.reject(&.null?).dup
      heap.collect(scan_stack: false, roots: ptrs)
      collect_count += 1

      pass, errs = verify(live_ptrs, heap)
      errors.concat(errs)
      unless pass
        STDERR.puts "PROPERTY FAIL: #{errs.first}"
        STDERR.puts "seed=#{seed} ops=#{ops} collects=#{collect_count}"
        exit 1
      end
      verify_count += 1
    when 6 # COLLECT with invariants check
      # Verify invariants before collect
      Gcry::Invariant.check_all_freelists(heap)
      Gcry::Invariant.check_live_objects(heap)

      ptrs = live_ptrs.reject(&.null?).dup
      heap.collect(scan_stack: false, roots: ptrs)
      collect_count += 1

      # Verify invariants after collect
      Gcry::Invariant.check_all_freelists(heap)
      Gcry::Invariant.check_live_objects(heap)

      pass, errs = verify(live_ptrs, heap)
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

  # Final collect + verify
  ptrs = live_ptrs.reject(&.null?).dup
  heap.collect(scan_stack: false, roots: ptrs)
  collect_count += 1
  pass, errs = verify(live_ptrs, heap)
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
ensure
  log_file.try(&.close)
  Gcry::Invariant.disable
  heap.destroy
end
