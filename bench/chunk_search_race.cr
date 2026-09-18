# Schedule a trim between a small-allocation search loading a chunk pointer
# and inspecting its kind. Run with Boehm so the scheduler's own allocations
# do not touch the heap under test. No timing assumptions or production hooks.
require "../src/gcry"
require "./bounded_child"

module ChunkSearchRace
  class_property after_take : Proc(Gcry::ChunkHeader*, Nil)?
  class_property after_revive : Proc(Gcry::ChunkHeader*, Nil)?
  class_property before_grow : Proc(Nil)?
  @@target = Atomic(UInt64).new(0_u64)
  @@stage = Atomic(Int32).new(0)

  def self.arm(address : UInt64)
    @@target.set(address)
  end

  def self.target : UInt64
    @@target.get
  end

  def self.stage=(value : Int32)
    @@stage.set(value)
  end

  def self.wait(value : Int32)
    until @@stage.get >= value
      Thread.yield
    end
  end

  def self.before_read(chunk : Gcry::ChunkHeader*)
    return unless @@target.compare_and_set(chunk.address, 0_u64)[1]
    self.stage = 1
    wait(2)
  end
end

struct Gcry::ChunkHeader
  def self.set_dormant(chunk : ChunkHeader*, value : Bool) : Nil
    previous_def
    ChunkSearchRace.after_revive.try(&.call(chunk)) unless value
  end

  def self.large?(chunk : ChunkHeader*) : Bool
    ChunkSearchRace.before_read(chunk)
    previous_def
  end
end

struct Crystal::SpinLock
  # Test-only nonblocking acquisition. The peer trims immediately if the
  # reader permits it; otherwise it waits until that reader has finished.
  def chunk_search_try_lock : Bool
    @m.compare_and_set(0, 1, :acquire, :relaxed)[1]
  end
end

class Gcry::Heap
  protected def bitmap_take_pool_chunk(index : Int32, payload : UInt32,
                                       atomic : Bool) : ChunkHeader*
    chunk = previous_def
    ChunkSearchRace.after_take.try(&.call(chunk))
    chunk
  end

  private def bitmap_pool_grow(pool : BitmapPoolIndex*, needed : Int32) : Bool
    ChunkSearchRace.before_grow.try(&.call) if needed > 1
    previous_def
  end

  # Schedule the in-STW sweep while the allocating thread still holds its
  # class lock, then the post-STW release before refill receives its chunk.
  # Calling the phases directly keeps this schedule independent of signals.
  def chunk_search_sweep_handoff(chunk : ChunkHeader*) : Nil
    @release_warm_this_collect = true
    @world_stopped = true
    begin
      sweep(true)
    ensure
      @world_stopped = false
      @release_warm_this_collect = false
    end
    flush_pending_empty_chunks
    raise "handoff lost cursor ownership" unless ChunkHeader.cursor?(chunk)
  end

  def chunk_search_handoff_probe(mode : String, atomic : Bool) : Nil
    rounded, index = SizeClasses.fit(48_u64)
    flags = atomic ? ChunkHeader::Flags::ATOMIC : 0_u32
    slot = atomic ? index + SIZE_CLASS_COUNT : index
    pool = @bitmap_pool_indexes.to_unsafe + slot
    target = Pointer(ChunkHeader).null
    unless mode == "handoff-fresh"
      target = map_chunk(@small_chunk_bytes, index.to_u32, flags)
      raise "failed to map handoff target" if target.null?
      raise "failed to allocate handoff pool" unless bitmap_pool_grow(pool, 1)
      case mode
      when "handoff-cached"
        pool.value.addresses[0] = target.address
        pool.value.count = 1
        pool.value.next_index = 0
        pool.value.version = Atomic::Ops.load(@bitmap_capacity_versions.to_unsafe + slot,
          LLVM::AtomicOrdering::Acquire, false)
        pool.value.blacklist_enabled = @blacklist_enabled
        pool.value.valid = true
      when "handoff-overflow"
        other = map_chunk(@small_chunk_bytes, index.to_u32, flags)
        raise "failed to map overflow target" if other.null?
        target = other if other.address < target.address
        # Keep the real buffer but force the lowest-address fallback with
        # two candidates. The grow hook runs after list protection ends.
        pool.value.capacity = 1
      when "handoff-dormant"
        ChunkHeader.set_dormant(target, true)
      else
        raise "unknown handoff mode"
      end
    end

    took = false
    grew = false
    revived = false
    ChunkSearchRace.after_take = ->(chunk : ChunkHeader*) {
      chunk_search_sweep_handoff(chunk)
      took = true
      nil
    }
    if mode == "handoff-overflow"
      ChunkSearchRace.before_grow = -> {
        chunk_search_sweep_handoff(target)
        grew = true
        nil
      }
    elsif mode == "handoff-dormant"
      ChunkSearchRace.after_revive = ->(chunk : ChunkHeader*) {
        # Revival still holds alloc here. Exercise the in-STW decision,
        # which takes neither alloc nor class locks; the release runs later.
        @world_stopped = true
        begin
          counts = sweep_small_blocks(chunk, index, true, false)
          raise "sweep reclaimed a chunk during revival" unless counts.any_live
        ensure
          @world_stopped = false
        end
        revived = true
        nil
      }
    end
    with_freelist_lock(index, false) do
      cursor = CursorSlot.new
      raise "handoff refill failed" unless bitmap_refill_pool(pointerof(cursor), index, rounded.to_u32, atomic)
      raise "handoff did not reach take" unless took
      raise "handoff did not reach overflow" if mode == "handoff-overflow" && !grew
      raise "handoff did not reach revival" if mode == "handoff-dormant" && !revived
      raise "handoff changed chunk kind" unless ChunkHeader.atomic?(cursor.chunk) == atomic
      raise "handoff lost free capacity" if cursor.free_mask == 0
      retire_cursor_slot(pointerof(cursor))
    end
  ensure
    ChunkSearchRace.after_take = nil
    ChunkSearchRace.after_revive = nil
    ChunkSearchRace.before_grow = nil
  end

  def chunk_search_stopped_probe : Nil
    @chunk_list_lock.sync do
      @world_stopped = true
      begin
        each_chunk_for_allocation { |_chunk| }
      ensure
        @world_stopped = false
      end
    end
  end

  def chunk_search_trim_peer : Nil
    ChunkSearchRace.wait(1)
    if @chunk_list_lock.chunk_search_try_lock
      @chunk_list_lock.unlock
      trim_large_cache(0_u64)
      ChunkSearchRace.stage = 2
    else
      ChunkSearchRace.stage = 2
      ChunkSearchRace.wait(3)
      trim_large_cache(0_u64)
    end
  end

  def chunk_search_probe(mode : String) : Nil
    rounded, index = SizeClasses.fit(48_u64)
    payload = rounded.to_u32
    with_freelist_lock(index, false) do
      case mode
      when "pool"
        bitmap_take_pool_chunk(index, payload, false)
      when "cached-pool"
        slot = index
        pool = @bitmap_pool_indexes.to_unsafe + slot
        raise "failed to allocate test bitmap pool" unless bitmap_pool_grow(pool, 1)
        pool.value.addresses[0] = ChunkSearchRace.target
        pool.value.count = 1
        pool.value.next_index = 0
        pool.value.version = Atomic::Ops.load(@bitmap_capacity_versions.to_unsafe + slot,
          LLVM::AtomicOrdering::Acquire, false)
        pool.value.blacklist_enabled = @blacklist_enabled
        pool.value.valid = true
        bitmap_take_pool_chunk(index, payload, false)
      when "bitmap-dormant"
        bitmap_revive_dormant(index, false)
      when "header-dormant"
        revive_dormant_chunk(index, payload, false)
      else
        raise "unknown mode"
      end
    end
  end
end

if ARGV.first? == "--child"
  mode = ARGV[1]
  # This is a library build — gcry is not the process GC here, so `GC.init`
  # never runs and nothing installs the SIGSEGV report. A deterministic fault in
  # this harness therefore printed exactly one line on the Darwin runner, twice:
  # `Process terminated because of an invalid memory access`, with no address,
  # no backtrace and no release ledger, which cost two CI rounds and settled
  # nothing (`bench/log/linux/2026-09-17-darwin-64-thread-cliff/HALF2-REVERT.md`).
  # Same one-liner as `large_cache_race.cr` and `dormant_flush_race.cr`, and the
  # recipe sets the variable so CI gets the report without anyone remembering to.
  # Unix-only: `segv_report.cr` opens with `{% skip_file unless flag?(:unix) %}`,
  # and `spec/cached_bitmap_pool_race_spec.cr` builds this harness — so an
  # unguarded call breaks all six Windows jobs, which is what it did on the
  # commit that added it. Same shape as the `poison_holders.cr` break two days
  # earlier; `make windows-typecheck` now covers this file for that reason.
  {% if flag?(:unix) %}
    Gcry::SegvReport.install if ENV["GCRY_SEGV_REPORT"]? == "1"
  {% end %}
  heap = Gcry::Heap.new
  heap.bitmap_alloc = mode != "header-dormant"
  heap.gc_threshold = UInt64::MAX
  heap.large_cache_retain = 64_u64 << 20
  # PROT_NONE prevents address reuse from hiding a stale read.
  heap.unmap_guard = true
  if mode.starts_with?("handoff-")
    heap.nursery_enabled = false
    heap.release_empty_chunks = true
    heap.empty_chunk_retain = 0_u64
    heap.empty_chunk_warm_retain = 0_u64
    heap.chunk_search_handoff_probe(mode, ARGV[2]? == "atomic")
    heap.destroy
    puts "#{mode}: cursor survived a sweep during handoff"
    exit 0
  end
  pointer = heap.malloc_atomic(40 * 1024)
  chunk = (Gcry::BlockHeader.large_header_from_user(pointer).as(UInt8*) - Gcry::ChunkHeader::SIZE).as(Gcry::ChunkHeader*)
  heap.free(pointer)
  if mode == "stopped"
    heap.chunk_search_stopped_probe
    heap.destroy
    puts "stopped: search did not wait on a suspended owner's lock"
    exit 0
  end
  ChunkSearchRace.arm(chunk.address)
  peer = Thread.new { heap.chunk_search_trim_peer }
  heap.chunk_search_probe(mode)
  ChunkSearchRace.stage = 3
  peer.join
  heap.destroy
  puts "#{mode}: search survived concurrent trim"
  exit 0
end

exe = Process.executable_path.not_nil!
failures = [] of String
["pool", "cached-pool", "bitmap-dormant", "header-dormant", "stopped",
 "handoff-cached", "handoff-overflow", "handoff-dormant", "handoff-fresh"].each do |mode|
  result = BoundedChild.run(exe, ["--child", mode], timeout: 10.seconds)
  puts result.output
  next if result.ok

  # Name the arm. Every child prints its own `ok` line and exits 0, so a crash
  # at exit — after that line — is indistinguishable from the parent dying,
  # which is exactly how two Darwin runs of a deterministic fault could not say
  # which of nine arms produced it.
  failures << (result.timed_out ? "#{mode} (exceeded its 10s budget)" : mode)
end

unless failures.empty?
  STDERR.puts "FAIL: #{failures.join(", ")} — the output above is that child's, " \
              "stdout and stderr together"
  exit 1
end
exit 0
