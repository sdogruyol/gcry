require "../../src/gcry"
require "spec"

# The sorted chunk index grows by `malloc`, from inside `map_chunk`, with the
# caller's class lock or `@alloc_lock` held and `@chunk_list_lock` and
# `@index_lock` under it. Until 2026-10-11 a refused `malloc` there raised
# `OutOfMemoryError` on the spot: building the error allocates, and an
# allocation that needed a chunk of its own spun on the `@chunk_list_lock`
# its thread already held. A plain program allocating 400 000 small `Array`s,
# with the one `malloc(4096)` that grows the index to 512 entries refused,
# spun at 100% CPU forever. An error that did get out left a chunk on the
# list and in the radix table that the sorted index and `@heap_size` never
# saw.
#
# `Heap#test_fail_next_index_grow` refuses the next growth once, through the
# size-class refill and then through a large allocation. Each must come back
# as an allocation or an `OutOfMemoryError`, and the heap must agree with
# itself afterwards.

private INDEX_OOM_SMALL =   2000
private INDEX_OOM_LARGE = 40_000
# Allocations a phase may take to reach the next growth: a size-class chunk
# holds ~60 of the small ones, so this is ~3 000 chunks.
private INDEX_OOM_LIMIT = 200_000
# A passing child takes milliseconds; this only bounds a hang.
private INDEX_OOM_TIMEOUT = 30.seconds

# Allocate until the refused growth has happened; what the allocation that
# met it did.
private def index_oom_phase(heap : Gcry::Heap, holder : Array(Void*), size : Int32, atomic : Bool) : String
  heap.test_fail_next_index_grow = true
  raised = false
  INDEX_OOM_LIMIT.times do |i|
    begin
      bytes = LibC::SizeT.new(size)
      holder << (atomic ? GC.malloc_atomic(bytes) : GC.malloc(bytes))
    rescue Gcry::OutOfMemoryError
      raised = true
    end
    unless heap.test_fail_next_index_grow
      return "#{raised ? "raised" : "recovered"} at allocation #{i + 1} (#{heap.chunk_index_count} chunks)"
    end
  end
  heap.test_fail_next_index_grow = false
  fail "the chunk index never grew in #{INDEX_OOM_LIMIT} allocations of #{size} bytes"
end

# Every chunk on the list is indexed and counted in the heap size, and every
# object handed out resolves to its chunk.
private def index_oom_consistent(heap : Gcry::Heap, holder : Array(Void*)) : Nil
  listed = 0
  mapped = 0_u64
  heap.each_chunk do |chunk|
    listed += 1
    mapped += chunk.value.mapped_bytes
  end
  listed.should eq(heap.chunk_index_count)
  mapped.should eq(heap.heap_size)
  unresolved = holder.count { |p| !heap.chunk_containing_public?(p.address) }
  unresolved.should eq(0)
end

describe "Regression: a refused chunk-index growth" do
  # In a process of its own: before the fix the allocation spun forever with
  # the chunk list locked, which would take the whole suite down.
  it "fails the allocation instead of hanging, and leaves the heap consistent" do
    output = IO::Memory.new
    child = Process.new(Process.executable_path.not_nil!, ["-e", "chunk-index-oom child"],
      env: {"GCRY_CHUNK_INDEX_OOM_CHILD" => "1"}, output: output, error: output)
    deadline = Time.instant + INDEX_OOM_TIMEOUT
    until child.terminated?
      if Time.instant > deadline
        child.terminate(graceful: false)
        child.wait
        fail "the child hung for #{INDEX_OOM_TIMEOUT}:\n#{output}"
      end
      sleep 10.milliseconds
    end
    status = child.wait
    fail output.to_s unless status.success?
    output.to_s.should contain("1 examples, 0 failures")
  end

  # The run, by the example above in a fresh process; a no-op anywhere else.
  it "chunk-index-oom child" do
    next unless ENV["GCRY_CHUNK_INDEX_OOM_CHILD"]? == "1"
    heap = Gcry.default_heap
    # Sized up front, so the loop's own allocations are the ones it makes.
    holder = Array(Void*).new(2 * INDEX_OOM_LIMIT + 2)
    GC.collect

    # The reviewer's shape: the class refill, under its class lock.
    small = index_oom_phase(heap, holder, INDEX_OOM_SMALL, atomic: false)
    index_oom_consistent(heap, holder)
    # `alloc_large`, under `@alloc_lock`.
    large = index_oom_phase(heap, holder, INDEX_OOM_LARGE, atomic: true)
    index_oom_consistent(heap, holder)
    puts "chunk-index-oom: small #{small}, large #{large}"

    GC.collect
    index_oom_consistent(heap, holder)
    holder << GC.malloc(LibC::SizeT.new(INDEX_OOM_SMALL))
    holder << GC.malloc_atomic(LibC::SizeT.new(INDEX_OOM_LARGE))
    GC.collect
    index_oom_consistent(heap, holder)
  end
end
