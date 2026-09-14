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
# Both arms also disable the nursery, and that is not incidental. A library
# heap enables it by default, and nursery chunks deliberately keep the header
# representation — their allocation still runs through `alloc_nursery`'s
# freelist, so `occ` is not maintained for them (nursery-on-bitmaps is Phase 8).
# With the nursery on, the bitmap arm would allocate through the freelist and
# these specs would exercise the header path under a bitmap name.
private def bitmap_heap : Gcry::Heap
  heap = Gcry::Heap.new
  heap.bitmap_alloc = true # implies bitmap_marks; Phase 3 representation
  heap.nursery_enabled = false
  heap
end

private def header_heap : Gcry::Heap
  heap = Gcry::Heap.new
  heap.bitmap_marks = false
  heap.nursery_enabled = false
  heap
end

# The third representation, and the one `GCRY_BITMAP=1` selects on the header
# layout: marks in the chunk's bitmap while the *freelist* allocator keeps
# handing out header-carrying blocks. It is neither of the other two - the
# bitmap arm retires the freelist for the pool cursor, the header arm keeps
# marks in the block - and until 2026-09-14 nothing ran it. The headerless
# default forces both bitmaps on, `GCRY_BITMAP_ALLOC=1` covers marks-plus-pool,
# and the one CI line that set `GCRY_BITMAP=1` set it on a binary built
# headerless, which ignores the knob.
private def marks_only_heap : Gcry::Heap
  heap = Gcry::Heap.new
  # Both set explicitly, and the allocator first: under
  # `GCRY_BITMAP_ALLOC=1 crystal spec` a heap left to its default already has
  # the pool cursor, and `bitmap_marks = true` would not take it back - the
  # arm would silently be a second bitmap arm, which is the failure this file
  # exists to avoid.
  heap.bitmap_alloc = false
  heap.bitmap_marks = true # the freelist allocator stays
  heap.nursery_enabled = false
  heap
end

# Every representation this layout has, newest last. Compared against the
# first arm rather than pairwise: "the same live set" is one claim about all
# of them, and a three-way disagreement should name which arm drifted.
private def mark_arms : Array({String, Proc(Gcry::Heap)})
  {% if flag?(:gcry_block_headers) %}
    [{"header", -> { header_heap }},
     {"marks-only", -> { marks_only_heap }},
     {"bitmap", -> { bitmap_heap }}]
  {% else %}
    # Headerless has one: no header to hold a mark, no freelist to run.
    [{"bitmap", -> { bitmap_heap }}]
  {% end %}
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
          # The field points at the block header (header build) or at the object
          # itself (headerless, where the large header sits behind the object).
          large_offset = {% if !flag?(:gcry_block_headers) %} Gcry::ChunkHeader.large_data_offset {% else %} Gcry::ChunkHeader::SIZE {% end %}
          chunk.value.data_offset.should eq(large_offset.to_u32)
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

  {% if flag?(:gcry_block_headers) %}
    # Headerless has no header to fall back to; the representation cannot be off.
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
  {% end %}

  {% if flag?(:gcry_block_headers) %}
    # Headerless has no header to fall back to; the representation cannot be off.
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
  {% end %}

  {% if flag?(:gcry_block_headers) %}
    # What `GCRY_BITMAP=1` actually selects, asserted rather than assumed: the
    # gate that runs the suite under that knob is only testing a third
    # representation if the knob still produces one. If a default flip ever
    # made it imply the pool allocator, this fails and `make
    # bitmap-marks-freelist` stops being about the arm it names.
    it "is the arm GCRY_BITMAP=1 selects, freelist and all" do
      previous = ENV["GCRY_BITMAP"]?
      previous_alloc = ENV["GCRY_BITMAP_ALLOC"]?
      ENV["GCRY_BITMAP"] = "1"
      # Stated, not inherited: under `GCRY_BITMAP_ALLOC=1 crystal spec` this
      # would otherwise read the pool allocator's arm and call it this one.
      # `0` is also what a `-Dgc_none` caller must pass, since the process GC
      # defaults that knob on while a library heap defaults it off.
      ENV["GCRY_BITMAP_ALLOC"] = "0"
      heap = Gcry::Heap.new
      begin
        heap.bitmap_marks?.should be_true
        heap.bitmap_alloc?.should be_false
      ensure
        heap.destroy
        previous ? (ENV["GCRY_BITMAP"] = previous) : ENV.delete("GCRY_BITMAP")
        if previous_alloc
          ENV["GCRY_BITMAP_ALLOC"] = previous_alloc
        else
          ENV.delete("GCRY_BITMAP_ALLOC")
        end
      end
    end

    # The geometry of that arm is both things at once, which is the reason it
    # can fail where neither of its neighbours does: a chunk carries a mark
    # bitmap *and* its blocks carry headers, so every site that decides where
    # a block starts has to agree with `data_offset` while the freelist
    # threads `next_free` through the header it still has.
    it "carves a mark bitmap while blocks keep their headers" do
      heap = marks_only_heap
      begin
        heap.bitmap_alloc?.should be_false
        keep = heap.malloc(64)
        heap.add_root(keep)
        300.times { heap.malloc(64) }
        heap.collect(scan_stack: false)
        heap.live?(keep).should be_true

        Gcry::BlockHeader::SIZE.should be > 0
        small = 0
        heap.each_chunk do |chunk|
          next if Gcry::ChunkHeader.large?(chunk)
          small += 1
          chunk.value.bitmap_words.should be > 0_u32
          Gcry::ChunkHeader.mark_bitmap(chunk).should_not eq(Pointer(UInt64).null)
          chunk.value.data_offset.should be > Gcry::ChunkHeader::SIZE.to_u32
          # The freelist allocator keeps `occ` unmaintained; the bitmap arm is
          # the one that publishes it. Asking for it here would pass for the
          # wrong reason on a heap that had silently switched allocators.
        end
        small.should be > 0
      ensure
        heap.destroy
      end
    end
  {% end %}

  it "publishes survivors into occ and leaves mark clear" do
    # The sweep is `occ = mark; mark = 0` in one streaming pass, so after a
    # collection a survivor is recorded in `occ` and the mark bitmap is empty.
    # Asserting on `mark` here — as this spec did while the sweep still walked
    # headers — now tests the wrong bitmap.
    heap = bitmap_heap
    begin
      keep = heap.malloc(64)
      heap.add_root(keep)
      200.times { heap.malloc(64) }
      heap.collect(scan_stack: false)
      heap.live?(keep).should be_true

      header = Gcry::BlockHeader.from_user(keep)
      found = false
      heap.each_chunk do |chunk|
        next if Gcry::ChunkHeader.large?(chunk)
        lo = Gcry::ChunkHeader.data_start(chunk).address
        hi = chunk.address + chunk.value.mapped_bytes
        next unless header.address >= lo && header.address < hi
        block_bytes = Gcry::BlockHeader::SIZE.to_u64 + heap.block_payload(chunk, header).to_u64
        ordinal = (header.address - lo) // block_bytes
        occ = Gcry::ChunkHeader.occ_bitmap(chunk)
        mark = Gcry::ChunkHeader.mark_bitmap(chunk)
        occ.should_not eq(Pointer(UInt64).null)
        # The survivor is allocated...
        ((occ[ordinal >> 6] >> (ordinal & 63)) & 1_u64).should eq(1_u64)
        # ...and the garbage around it is not: 201 allocated, 1 survives.
        total = 0
        chunk.value.bitmap_words.to_i32.times { |w| total += occ[w].popcount }
        total.should eq(1)
        # Marks were consumed by the same pass that published occ.
        chunk.value.bitmap_words.to_i32.times { |w| mark[w].should eq(0_u64) }
        found = true
      end
      found.should be_true
    ensure
      heap.destroy
    end
  end

  it "decides the same live set whichever representation holds the marks" do
    # The A/B, now three-way on the header layout. Same graph, same roots, same
    # collections; the only difference is where marks are recorded and which
    # allocator hands the blocks out.
    results = [] of {String, Int32, UInt64, UInt64}
    mark_arms.each do |name, build|
      heap = build.call
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
        results << {name, walked, checksum, heap.live_objects}
      ensure
        heap.destroy
      end
    end

    first = results.first
    first[1].should eq(200) # the whole chain walked
    results.each do |arm|
      # Named in the message: a three-way comparison that fails should say
      # which representation drifted, not just that one did.
      fail "#{arm[0]}: walked #{arm[1]}, #{first[0]} walked #{first[1]}" if arm[1] != first[1]
      fail "#{arm[0]}: checksum #{arm[2]}, #{first[0]} #{first[2]}" if arm[2] != first[2]
      fail "#{arm[0]}: live_objects #{arm[3]}, #{first[0]} #{first[3]}" if arm[3] != first[3]
    end
  end

  it "reclaims garbage at the same rate under every representation" do
    counts = [] of {String, UInt64}
    mark_arms.each do |name, build|
      heap = build.call
      begin
        keep = heap.malloc(64)
        heap.add_root(keep)
        500.times { heap.malloc(64) }
        heap.collect(scan_stack: false)
        heap.live?(keep).should be_true
        counts << {name, heap.live_objects}
      ensure
        heap.destroy
      end
    end
    first = counts.first
    counts.each do |arm|
      fail "#{arm[0]}: #{arm[1]} live, #{first[0]}: #{first[1]}" if arm[1] != first[1]
    end
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
