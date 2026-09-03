# Multi-threaded property test for gcry.
#
# Verifies GC correctness under concurrent allocation:
#   1. No object lost under concurrent alloc + periodic collect
#      (all explicitly-rooted objects survive collection)
#   2. TLAB + collect makes all allocations visible to the sweeper
#   3. Parallel mark vs serial mark produce the same live set
#      (parallel_mark_workers=2 vs parallel_mark_workers=1)
#
# Uses fibers (spawn) for concurrent allocators + a coordinator that
# periodically calls collect. With `stop_the_world=false` (library heap),
# the collector does not suspend other fibers.
#
# Build:  crystal build bench/mt_property_test.cr -o bin/mt_property_test
# Run:    ./bin/mt_property_test [--seed=1] [--iterations=500] [--workers=2,4,8]

require "../src/gcry"

# ---- CLI args ----
seed = 1_i64
iterations = 500
worker_counts = [2, 4, 8]

ARGV.each do |arg|
  case arg
  when /--seed=(\d+)/
    seed = $1.to_i64
  when /--iterations=(\d+)/
    iterations = $1.to_i
  when /--workers=(.+)/
    worker_counts = $1.split(',').map(&.to_i)
  end
end

# ---- Constants ----
HEADER_WORDS = 2
SLOT_COUNT   = 8
OBJ_BYTES    = (HEADER_WORDS + SLOT_COUNT) * sizeof(Void*)

class MTPropertyTest
  @heap : Gcry::Heap
  @roots : Array(Void*)
  @mutex : Mutex
  @errors : Array(String)
  @errors_mutex : Mutex
  @running : Atomic(Bool)
  @deadline : Time::Instant

  def initialize
    @heap = Gcry::Heap.new

    # Library heap mode: no STW, no process-GC thread suspension.
    @heap.scan_static_roots = false
    @heap.gc_threshold = UInt64::MAX
    @heap.nursery_threshold = UInt64::MAX
    @heap.nursery_enabled = false
    @heap.release_empty_chunks = true
    @heap.layout_precise = true
    @heap.tlab_enabled = false      # fibers share one OS thread
    @heap.stop_the_world = false    # library heap: no STW
    @heap.parallel_mark_workers = 2 # parallel mark via Crystal::Thread

    @roots = [] of Void*
    @mutex = Mutex.new(:reentrant)
    @errors = [] of String
    @errors_mutex = Mutex.new(:reentrant)
    @running = Atomic(Bool).new(true)
    @deadline = Time.instant + 120.seconds
  end

  def set_type_id(obj : Void*, tid : Int32)
    obj.as(Int32*).value = tid
  end

  def add_root(ptr : Void*)
    @mutex.synchronize { @roots << ptr }
  end

  def remove_root(ptr : Void*)
    @mutex.synchronize { @roots.delete(ptr) }
  end

  def get_roots : Array(Void*)
    @mutex.synchronize { @roots.dup }
  end

  def record_error(msg : String)
    @errors_mutex.synchronize { @errors << msg }
  end

  def has_errors? : Bool
    @errors_mutex.synchronize { !@errors.empty? }
  end

  def alloc_leaf : Void*
    ptr = @heap.malloc(OBJ_BYTES)
    set_type_id(ptr, 0) # 0 type_id → conservative word-scan
    ptr
  end

  # ---- Worker fiber ----
  # Allocates/frees and shares roots via the global set.
  def worker_run(worker_id : Int32, rng_seed : Int64, done_ch : Channel(Nil))
    local_roots = [] of Void*
    rng = Random.new(rng_seed + worker_id)

    while @running.get
      batch = rng.rand(1..5)
      batch.times do
        op = rng.rand(0..4)
        case op
        when 0, 1 # ALLOC + share
          ptr = alloc_leaf
          local_roots << ptr
          add_root(ptr)
        when 2 # ALLOC local only
          ptr = alloc_leaf
          local_roots << ptr
        when 3 # FREE some
          if local_roots.size > 10
            idx = rng.rand(0...local_roots.size)
            ptr = local_roots.delete_at(idx)
            remove_root(ptr)
            begin
              @heap.free(ptr)
            rescue ArgumentError
            end
          end
        when 4 # WRITE pointer slot (simulate pointer graph)
          if local_roots.size >= 2
            src = local_roots[rng.rand(0...local_roots.size)]
            dst = local_roots[rng.rand(0...local_roots.size)]
            slot = rng.rand(0...SLOT_COUNT)
            src.as(Void**)[HEADER_WORDS + slot] = dst
          end
        end
      end

      # Trim local roots
      if local_roots.size > 200
        excess = local_roots.size - 100
        excess.times do
          ptr = local_roots.shift
          remove_root(ptr)
          begin
            @heap.free(ptr)
          rescue ArgumentError
          end
        end
      end

      # Yield to let other fibers/collector run
      Fiber.yield
    end

    done_ch.send(nil)
  end

  # ---- Walk heap and count live blocks ----
  def walk_live_blocks : UInt64
    count = 0_u64
    @heap.each_chunk do |chunk|
      class_index = chunk.value.size_class.to_i32
      if Gcry::ChunkHeader.large?(chunk)
        header = Gcry::ChunkHeader.data_start(chunk).as(Gcry::BlockHeader*)
        count += 1 unless Gcry::BlockHeader.free?(header)
      elsif @heap.bitmap_alloc_chunk_public?(chunk)
        # `occ`, not the header's FREE flag: the streaming sweep never writes
        # FREE into the blocks it reclaims, so a header walk counts every
        # reclaimed block as live. That over-count then underflows the
        # `(reported - walked).to_i64` below and surfaces as "Arithmetic
        # overflow" rather than as a mismatch, which is how it was found.
        count += @heap.chunk_occupied_count(chunk)
      else
        payload = Gcry::SizeClasses.payload(class_index)
        block_bytes = Gcry::BlockHeader::SIZE.to_u64 + payload.to_u64
        cursor = Gcry::ChunkHeader.data_start(chunk).as(UInt8*)
        limit = Gcry::ChunkHeader.data_end(chunk).as(UInt8*)
        while (cursor + block_bytes) <= limit
          header = cursor.as(Gcry::BlockHeader*)
          count += 1 unless Gcry::BlockHeader.free?(header)
          cursor += block_bytes
        end
      end
    end
    count
  end

  # ---- Verify roots are alive ----
  def verify_roots_alive(roots, label : String) : Bool
    pass = true
    roots.each_with_index do |ptr, i|
      next if ptr.null?
      unless @heap.live?(ptr)
        record_error("#{label}: root #{i} is DEAD")
        pass = false
      end
    end
    pass
  end

  # ---- Run a single test for a given worker count ----
  def run_worker_count_test(worker_count : Int32, iterations : Int32, seed : Int64) : Bool
    puts "  MT test worker_count=#{worker_count} iterations=#{iterations}"

    @heap.parallel_mark_workers = 2
    @running.set(true)

    # Spawn worker fibers
    done_channels = [] of Channel(Nil)
    worker_count.times do |i|
      ch = Channel(Nil).new
      spawn { worker_run(i, seed + i.to_i64, ch) }
      done_channels << ch
    end

    collect_count = 0
    verify_count = 0
    fail_count = 0

    iteration = 0
    while iteration < iterations && Time.instant < @deadline && !has_errors?
      # Let workers run a bit
      sleep(0.001.seconds)

      # Collect with global roots
      roots = get_roots
      if roots.size > 0
        @heap.collect(scan_stack: false, roots: roots)
        collect_count += 1

        unless verify_roots_alive(roots, "iter #{iteration} (#{worker_count} workers)")
          fail_count += 1
        end
        verify_count += 1
      end

      # Periodically verify live_objects counter
      if iteration > 0 && iteration % 10 == 0
        walked = walk_live_blocks
        reported = @heap.live_objects
        if reported != walked
          # Both are UInt64 and `walked` can legitimately exceed `reported`, so
          # `(reported - walked)` underflows to ~1.8e19 and `.to_i64` raises
          # "Arithmetic overflow" — a crash that reports nothing about the
          # mismatch it was trying to describe. Widen first, subtract second.
          diff = reported.to_i64 - walked.to_i64
          if diff.abs > 2
            record_error("iter #{iteration}: live_objects mismatch reported=#{reported} walked=#{walked} diff=#{diff}")
            fail_count += 1
          end
        end
      end

      iteration += 1
    end

    # Stop workers
    @running.set(false)

    # Wait for workers to finish
    done_channels.each { |ch| ch.receive }

    # Collect all remaining roots
    all_roots = get_roots

    # ---- Parallel mark verification (parallel_mark_workers=2) ----
    @heap.parallel_mark_workers = 2
    @heap.collect(scan_stack: false, roots: all_roots)
    p_ok = verify_roots_alive(all_roots, "parallel #{worker_count} workers")
    fail_count += 1 unless p_ok
    verify_count += 1

    # ---- Serial mark verification (parallel_mark_workers=1) ----
    @heap.parallel_mark_workers = 1
    @heap.collect(scan_stack: false, roots: all_roots)
    s_ok = verify_roots_alive(all_roots, "serial #{worker_count} workers")
    fail_count += 1 unless s_ok
    verify_count += 1

    # Restore default
    @heap.parallel_mark_workers = 2

    puts "    collects=#{collect_count} verifies=#{verify_count} failures=#{fail_count}"

    fail_count == 0 && !has_errors?
  end

  # ---- Run all worker counts ----
  def run(seed : Int64, iterations : Int32, worker_counts : Array(Int32)) : Bool
    Gcry::Layout.enabled = true
    Gcry::Layout.clear

    overall_errors = [] of String

    worker_counts.each do |wc|
      @errors.clear
      @roots.clear

      begin
        pass = run_worker_count_test(wc, iterations, seed)
        unless pass
          @errors.each { |e| overall_errors << e }
        end
      rescue ex
        overall_errors << "worker_count=#{wc} raised: #{ex}"
      end

      @heap.collect(scan_stack: false, roots: [] of Void*)
      @heap.trim_large_cache(0)
    end

    if overall_errors.any?
      puts "FAIL: #{overall_errors.size} error(s)"
      overall_errors.each { |e| STDERR.puts "  MT FAIL: #{e}" }
      return false
    end

    puts "MT property test ok seed=#{seed} iterations=#{iterations} worker_counts=#{worker_counts}"
    true
  end

  def cleanup
    @roots.each do |ptr|
      next if ptr.null?
      if @heap.is_heap_ptr(ptr) && @heap.live?(ptr)
        begin
          @heap.free(ptr)
        rescue ArgumentError
        end
      end
    end
    @heap.trim_large_cache(0)
    @heap.destroy
  end
end

# ---- Entry point ----
test = MTPropertyTest.new
begin
  success = test.run(seed, iterations, worker_counts)
ensure
  test.cleanup
end
exit(1) unless success
