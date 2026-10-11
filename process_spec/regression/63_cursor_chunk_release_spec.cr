require "../../src/gcry"
require "spec"

# The post-STW flush released a queued-empty chunk an allocation cursor stood
# on. The sweep unlinks an empty chunk and queues it, but its index entry
# lives until the flush, and a refill validates a pooled address against
# that index: it takes the chunk and sets CURSOR under `@chunk_list_lock`,
# then lets go of the lock before its first `occ` store. Until 2026-10-11
# the flush kept a queued chunk only when its `occ` popcount was non-zero, so
# a flush waiting on that lock read zero and unmapped the chunk under the
# cursor — and a cursor whose one block was freed again reads zero the same
# way. The next allocation of the class read the freed header: SIGSEGV in
# `fast_alloc`, with no refusal counted. CI run 34787711949 reached the
# window with real mutators.
#
# The construction is `bench/occupied_release.cr` (`make occupied-release`):
# a library heap, so nothing but this file allocates on the heap under test,
# and its two `post_stw_hook` stages on the collector's thread. The block the
# hook takes out of a queued chunk is freed again before the flush, which
# leaves `occ` empty with the cursor still on the chunk. Each arm runs in a
# process of its own: before the fix the first one dies of SIGSEGV.
#
# The heap's counters must also agree with its index afterwards. A refused
# chunk is mapped and indexed, but the sweep had already taken it out of
# `heap_size` and `free_bytes` when it queued it, and the major that later
# released it took it out again — 131072 bytes of `heap_size` for the two
# 131072-byte chunks `make occupied-release` left mapped.

private CURSOR_RELEASE_SIZE = 4096_u64

private def cursor_release_heap(control : Bool) : Gcry::Heap
  heap = Gcry::Heap.new
  heap.bitmap_alloc = true
  heap.nursery_enabled = false
  heap.gc_threshold = UInt64::MAX
  heap.release_empty_chunks = true
  heap.parallel_empty_chunk_dormant = true
  heap.parallel_empty_chunk_munmap = true
  heap.empty_chunk_warm_retain = 0_u64
  heap.empty_chunk_retain = 0_u64
  # The window is between the after-world sweep and the flush.
  heap.lazy_sweep = true
  heap.release_occupied_anyway = control
  heap
end

private def cursor_release_chunk_of(heap : Gcry::Heap, p : Void*) : UInt64
  found = heap.find_block_with_chunk(p)
  fail "#{p} is not in the heap under test" unless found
  found[1].address
end

private def cursor_release_indexed(heap : Gcry::Heap) : {Int32, UInt64}
  n = 0
  bytes = 0_u64
  heap.each_indexed_chunk do |chunk|
    n += 1
    bytes &+= chunk.value.mapped_bytes
  end
  {n, bytes}
end

# `heap_size`, the index and the mappings all describe the same chunks: the
# heap under test maps only small-class chunks of one size.
private def cursor_release_counters_agree(heap : Gcry::Heap, label : String) : Nil
  n, bytes = cursor_release_indexed(heap)
  mapped = heap.chunks_mapped &* heap.small_chunk_bytes &- heap.unmapped_bytes
  unless heap.heap_size == bytes && mapped == bytes
    fail "#{label}: heap_size=#{heap.heap_size}, #{n} indexed chunk(s) of #{bytes} bytes, " \
         "chunks_mapped=#{heap.chunks_mapped} less unmapped_bytes=#{heap.unmapped_bytes} is #{mapped}"
  end
end

# Walk the window: the first major puts every chunk on grace, the second
# queues them, and `:before_flush` takes a block out of a queued chunk. With
# *free_taken* the block is freed again at once, so the flush finds the chunk
# empty with the cursor on it. Returns the block and its chunk.
private def cursor_release_window(heap : Gcry::Heap, roots : Array(Void*),
                                  free_taken : Bool) : {Void*, UInt64}
  blocks_per_chunk = heap.small_chunk_bytes // CURSOR_RELEASE_SIZE
  (6 * blocks_per_chunk).times { heap.malloc(CURSOR_RELEASE_SIZE) }
  heap.collect(scan_stack: false)
  heap.empty_chunk_grace_kept.should be > 1

  mapped_before = heap.chunks_mapped
  considered_before = heap.release_flush_chunks
  first_chunk = 0_u64
  taken = Pointer(Void).null
  taken_chunk = 0_u64
  heap.post_stw_hook = ->(stage : Symbol) do
    case stage
    when :after_start_world
      p = heap.malloc(CURSOR_RELEASE_SIZE)
      roots << p
      first_chunk = cursor_release_chunk_of(heap, p)
    when :before_flush
      (blocks_per_chunk + 2).times do
        p = heap.malloc(CURSOR_RELEASE_SIZE)
        c = cursor_release_chunk_of(heap, p)
        if c != first_chunk
          taken = p
          taken_chunk = c
          break
        end
        roots << p
      end
      heap.free(taken) if free_taken && !taken.null?
    end
    nil
  end
  heap.collect(scan_stack: false, roots: roots)
  heap.post_stw_hook = nil

  # The construction must reach the window, or every arm passes on nothing:
  # a block came out of an already-mapped chunk the flush then considered.
  fail "no block was taken in the window" if taken.null?
  (heap.chunks_mapped - mapped_before).should eq(0)
  (heap.release_flush_chunks - considered_before).should be > 0
  {taken, taken_chunk}
end

describe "Regression: the empty-chunk flush keeps a chunk a cursor stands on" do
  {"cursor", "occupied", "control"}.each do |arm|
    it "#{arm} arm in a process of its own" do
      captured = IO::Memory.new
      status = Process.run(Process.executable_path.not_nil!, ["-e", "cursor-chunk-release child #{arm}"],
        env: {"GCRY_CURSOR_RELEASE_CHILD" => arm}, output: captured, error: captured)
      fail "child #{status.inspect}:\n#{captured}" unless status.success?
      captured.to_s.should contain("1 examples, 0 failures")
    end
  end

  # The block was freed: `occ` is empty and only the cursor says the chunk is
  # in use. Allocating from that cursor again is the access that faulted, so
  # it comes first.
  it "cursor-chunk-release child cursor" do
    next unless ENV["GCRY_CURSOR_RELEASE_CHILD"]? == "cursor"
    heap = cursor_release_heap(control: false)
    roots = [] of Void*
    refused_before = heap.release_refused_occupied
    taken, taken_chunk = cursor_release_window(heap, roots, free_taken: true)
    p = heap.malloc(CURSOR_RELEASE_SIZE)
    p.as(UInt8*).value = 0xA5_u8
    cursor_release_chunk_of(heap, p).should eq(taken_chunk)
    heap.is_heap_ptr(taken).should be_true
    (heap.release_refused_occupied - refused_before).should eq(0)
    cursor_release_counters_agree(heap, "after the flush")

    roots << p
    heap.collect(scan_stack: false, roots: roots)
    heap.live?(p).should be_true
    cursor_release_counters_agree(heap, "after a rooted collection")

    # Kept, not leaked: once nothing holds it the chunk goes, and the bytes
    # leave `heap_size` once rather than twice.
    roots.clear
    4.times { heap.collect(scan_stack: false) }
    heap.is_heap_ptr(p).should be_false
    cursor_release_counters_agree(heap, "after the chunk was released")
    heap.destroy
  end

  # The block stays allocated: the refusal this flush already made. Its
  # counters are the part that was wrong.
  it "cursor-chunk-release child occupied" do
    next unless ENV["GCRY_CURSOR_RELEASE_CHILD"]? == "occupied"
    heap = cursor_release_heap(control: false)
    roots = [] of Void*
    refused_before = heap.release_refused_occupied
    taken, _ = cursor_release_window(heap, roots, free_taken: false)
    (heap.release_refused_occupied - refused_before).should eq(1)
    heap.is_heap_ptr(taken).should be_true
    cursor_release_counters_agree(heap, "after the refused flush")
    roots << taken
    heap.collect(scan_stack: false, roots: roots)
    heap.live?(taken).should be_true
    cursor_release_counters_agree(heap, "after a rooted collection")
    heap.destroy
  end

  # `release_occupied_anyway` — the pre-fix decision — on the same
  # construction: the chunk goes. That the window is still reached on a
  # fixed tree is what makes the cursor arm's survival attributable. The
  # cursor still names the unmapped chunk, so nothing may allocate here after.
  it "cursor-chunk-release child control" do
    next unless ENV["GCRY_CURSOR_RELEASE_CHILD"]? == "control"
    heap = cursor_release_heap(control: true)
    roots = [] of Void*
    taken, _ = cursor_release_window(heap, roots, free_taken: true)
    heap.is_heap_ptr(taken).should be_false
  end
end
