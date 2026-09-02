require "./spec_helper"

# Per-chunk mark bitmaps (`GCRY_BITMAP=1`).
#
# The claim under test is not "the bitmap works" but "the bitmap and the header
# generation decide the same live set". A mark representation that disagrees
# with the old one by a single object is a use-after-free or a leak, and neither
# announces itself, so the important spec here is the A/B: run the same graph
# through two heaps that differ only in representation and require the same
# survivors.
# Both arms are set explicitly rather than left to `Heap.new`'s default,
# because that default reads `GCRY_BITMAP` from the environment — so under
# `GCRY_BITMAP=1 crystal spec` an implicit "header" arm would silently be a
# second bitmap arm and the A/B below would compare a thing to itself.
#
# Safe in both helpers and only here: no chunk has been carved yet.
# `data_offset` is baked into every chunk at map time, so flipping this later
# would leave chunks whose blocks start somewhere the heap no longer believes
# they do — which is what the setter refuses.
private def bitmap_heap : Gcry::Heap
  heap = Gcry::Heap.new
  heap.bitmap_marks = true
  heap
end

private def header_heap : Gcry::Heap
  heap = Gcry::Heap.new
  heap.bitmap_marks = false
  heap
end

# Build a chain of `n` linked blocks rooted at the first, plus `n` unreachable
# blocks, and return the root. Each node stores its successor in word 0 and a
# checksum in word 1, so a collector that reclaims a live node shows up as
# corruption rather than as a count.
private def build_graph(heap : Gcry::Heap, n : Int32) : Void*
  root = heap.malloc(64)
  cursor = root
  1.upto(n - 1) do |i|
    heap.malloc(64) # unreachable: dropped immediately
    node = heap.malloc(64)
    cursor.as(Void**).value = node
    (cursor.as(UInt64*) + 1).value = 0xC0FFEE_u64 &+ i
    cursor = node
  end
  (cursor.as(UInt64*) + 1).value = 0xC0FFEE_u64 &+ n
  cursor.as(Void**).value = Pointer(Void).null
  root
end

private def walk_graph(root : Void*) : Int32
  seen = 0
  cursor = root
  while cursor && !cursor.null?
    seen += 1
    cursor = cursor.as(Void**).value
  end
  seen
end

describe "Gcry::Heap mark bitmaps" do
  it "carves a bitmap region into size-class chunks and leaves large chunks alone" do
    heap = bitmap_heap
    begin
      heap.malloc(64)
      heap.malloc(40_000) # large: its own chunk

      small_seen = 0
      large_seen = 0
      heap.each_chunk do |chunk|
        if Gcry::ChunkHeader.large?(chunk)
          large_seen += 1
          # Large chunks keep the constant offset that twelve
          # `header - ChunkHeader::SIZE` back-references depend on.
          chunk.value.bitmap_words.should eq(0_u32)
          chunk.value.data_offset.should eq(Gcry::ChunkHeader::SIZE.to_u32)
          Gcry::ChunkHeader.mark_bitmap(chunk).should eq(Pointer(UInt64).null)
        else
          small_seen += 1
          chunk.value.bitmap_words.should be > 0_u32
          chunk.value.data_offset.should be > Gcry::ChunkHeader::SIZE.to_u32
          # The invariant every page-release site's safety rests on.
          chunk.value.data_offset.to_u64.should be < Gcry::Platform.host_page_size
        end
      end
      small_seen.should be > 0
      large_seen.should be > 0
    ensure
      heap.destroy
    end
  end

  it "leaves chunks bare when the representation is off" do
    heap = header_heap
    begin
      heap.bitmap_marks?.should be_false
      heap.malloc(64)
      heap.each_chunk do |chunk|
        chunk.value.bitmap_words.should eq(0_u32)
        chunk.value.data_offset.should eq(Gcry::ChunkHeader::SIZE.to_u32)
      end
    ensure
      heap.destroy
    end
  end

  it "refuses to change representation once chunks exist" do
    heap = header_heap
    begin
      heap.malloc(64) # carves a chunk at the old geometry
      expect_raises(ArgumentError, /cannot change once chunks are mapped/) do
        heap.bitmap_marks = true
      end
      # Setting it to the value it already holds is not a change.
      heap.bitmap_marks = false
      heap.bitmap_marks?.should be_false
    ensure
      heap.destroy
    end
  end

  it "actually records the trace in the bitmap, not only in the header" do
    heap = bitmap_heap
    begin
      keep = heap.malloc(64)
      heap.add_root(keep)
      heap.collect(scan_stack: false)
      heap.live?(keep).should be_true

      # Find the bit for `keep` and require it set. This is what distinguishes
      # "the bitmap path ran" from "the env var was ignored and the header
      # carried everything" — the union means the liveness assertions above
      # would pass either way.
      header = Gcry::BlockHeader.from_user(keep)
      found = false
      heap.each_chunk do |chunk|
        next if Gcry::ChunkHeader.large?(chunk)
        lo = Gcry::ChunkHeader.data_start(chunk).address
        hi = chunk.address + chunk.value.mapped_bytes
        next unless header.address >= lo && header.address < hi
        block_bytes = Gcry::BlockHeader::SIZE.to_u64 + header.value.size.to_u64
        ordinal = (header.address - lo) // block_bytes
        mark = Gcry::ChunkHeader.mark_bitmap(chunk)
        mark.should_not eq(Pointer(UInt64).null)
        ((mark[ordinal >> 6] >> (ordinal & 63)) & 1_u64).should eq(1_u64)
        found = true
      end
      found.should be_true
    ensure
      heap.destroy
    end
  end

  it "decides the same live set as the header generation" do
    # The A/B. Same graph, same roots, same collections; the only difference is
    # where marks are recorded.
    results = [] of Tuple(Bool, Int32, UInt64, UInt64)
    [false, true].each do |bitmap|
      heap = bitmap ? bitmap_heap : header_heap
      begin
        root = build_graph(heap, 200)
        heap.add_root(root)

        3.times { heap.collect(scan_stack: false) }

        # Every live node still reachable and uncorrupted.
        walked = walk_graph(root)
        checksum = 0_u64
        cursor = root
        while cursor && !cursor.null?
          checksum &+= (cursor.as(UInt64*) + 1).value
          cursor = cursor.as(Void**).value
        end
        results << {bitmap, walked, checksum, heap.live_objects}
      ensure
        heap.destroy
      end
    end

    header_arm, bitmap_arm = results[0], results[1]
    bitmap_arm[1].should eq(200)           # same chain length walked
    bitmap_arm[1].should eq(header_arm[1]) # same as the header arm
    bitmap_arm[2].should eq(header_arm[2]) # same payload checksums
    bitmap_arm[3].should eq(header_arm[3]) # same live-object count
  end

  it "reclaims garbage at the same rate under both representations" do
    counts = [] of UInt64
    [false, true].each do |bitmap|
      heap = bitmap ? bitmap_heap : header_heap
      begin
        keep = heap.malloc(64)
        heap.add_root(keep)
        500.times { heap.malloc(64) }
        heap.collect(scan_stack: false)
        heap.live?(keep).should be_true
        counts << heap.live_objects
      ensure
        heap.destroy
      end
    end
    counts[1].should eq(counts[0])
  end

  it "survives repeated collections without losing a rooted object" do
    # `clear_all_marks` zeroes bitmaps at the start of every cycle, so a
    # bookkeeping error there shows up as a live object vanishing on the second
    # or third collection rather than the first.
    heap = bitmap_heap
    begin
      root = build_graph(heap, 64)
      heap.add_root(root)
      10.times do
        heap.collect(scan_stack: false)
        walk_graph(root).should eq(64)
      end
    ensure
      heap.destroy
    end
  end

  it "keeps allocations 16-byte aligned under the bitmap geometry" do
    heap = bitmap_heap
    begin
      Gcry::SizeClasses::COUNT.times do |i|
        ptr = heap.malloc(Gcry::SizeClasses.payload(i).to_u64)
        (ptr.address % 16).should eq(0)
      end
    ensure
      heap.destroy
    end
  end
  it "sets shared bitmap words without losing a concurrent neighbour's mark" do
    # R1, the hazard the header representation structurally cannot have: 64
    # blocks share a mark word, so a plain `|=` from two threads marking
    # *different* objects drops one of them — a live object swept, presenting
    # as a rare load-dependent use-after-free.
    #
    # This exercises the primitive and the exact call shape `chunk_set_mark`
    # uses (relaxed pre-load, then atomic OR), which is the part that could be
    # got wrong silently. Whether every *site* uses it is what the MT gates
    # (`make mt-property-test`, `make stw-mt-property-test`) cover.
    threads = 8
    per_thread = 64
    words = (threads * per_thread + 63) // 64
    bitmap = Pointer(UInt64).malloc(words)
    words.times { |i| bitmap[i] = 0_u64 }

    done = Channel(Nil).new(threads)
    threads.times do |t|
      spawn do
        per_thread.times do |k|
          ordinal = (k * threads + t).to_u64
          word = bitmap + (ordinal >> 6)
          bit = 1_u64 << (ordinal & 63)
          next if (word.value & bit) != 0
          Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Or, word, bit,
            LLVM::AtomicOrdering::Monotonic, false)
        end
        done.send(nil)
      end
    end
    threads.times { done.receive }

    set = 0
    words.times { |i| set += bitmap[i].popcount }
    set.should eq(threads * per_thread)
  end
end
