# Schedule a trim between a small-allocation search loading a chunk pointer
# and inspecting its kind. Run with Boehm so the scheduler's own allocations
# do not touch the heap under test. No timing assumptions or production hooks.
require "../src/gcry"
require "./bounded_child"

module ChunkSearchRace
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
  heap = Gcry::Heap.new
  heap.bitmap_alloc = mode != "header-dormant"
  heap.gc_threshold = UInt64::MAX
  heap.large_cache_retain = 64_u64 << 20
  # PROT_NONE prevents address reuse from hiding a stale read.
  heap.unmap_guard = true
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
failed = false
["pool", "cached-pool", "bitmap-dormant", "header-dormant", "stopped"].each do |mode|
  result = BoundedChild.run(exe, ["--child", mode], timeout: 10.seconds)
  puts result.output
  failed ||= !result.ok
end
exit(failed ? 1 : 0)
