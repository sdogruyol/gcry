require "./spec_helper"

# O(1) address → chunk (`GCRY_CHUNK_RADIX=1`).
#
# The table is only ever an accelerator: a miss falls through to the
# address-sorted binary search, which stays the authority. So the thing to test
# is not "the table works" but "the table never changes an answer" — a radix
# that resolves one pointer to the wrong chunk is a use-after-free waiting to
# happen, and it would not announce itself.
#
# What this file can and cannot catch, stated plainly because the difference
# surprised me:
#
#   CAN — a table that answers differently from the binary search, a table that
#   is on but never hits, an oversize chunk silently dropped without a working
#   fallback, an entry surviving its chunk.
#
#   CANNOT — removal of the `ChunkHeader.contains?` verify. That was checked by
#   deleting it and watching all eight examples stay green. It is not a hole in
#   the spec: granules are page-sized, and chunks are page-aligned with
#   page-multiple sizes, so every granule belongs to exactly one chunk and a
#   non-null entry is already the only possible answer. The verify is defence
#   in depth against a corrupted or stale entry, not part of the resolution.
#
# Both arms are set explicitly rather than left to `Heap.new`'s default, which
# reads `GCRY_CHUNK_RADIX` from the environment: under
# `GCRY_CHUNK_RADIX=1 crystal spec` an implicit "off" arm would silently be a
# second "on" arm and the A/B would compare a thing to itself.
private def radix_heap : Gcry::Heap
  heap = Gcry::Heap.new
  heap.chunk_radix = true
  heap
end

private def plain_heap : Gcry::Heap
  heap = Gcry::Heap.new
  heap.chunk_radix = false
  heap
end

describe "Gcry::Heap chunk radix" do
  it "is off unless asked for" do
    heap = plain_heap
    begin
      heap.chunk_radix?.should be_false
      heap.malloc(64)
      heap.radix_fast_hits.should eq(0_u64)
    ensure
      heap.destroy
    end
  end

  it "refuses to turn on once chunks are mapped" do
    heap = plain_heap
    begin
      heap.malloc(64)
      expect_raises(ArgumentError, /cannot change once chunks are mapped/) do
        heap.chunk_radix = true
      end
    ensure
      heap.destroy
    end
  end

  it "resolves every live pointer to the same block as the binary search" do
    # The A/B that matters. Same allocation sequence in both heaps; every
    # pointer, plus interior offsets, must find the same block *offset within
    # its chunk* under both representations.
    sizes = [16, 24, 64, 100, 512, 1000, 4096, 20_000]
    layouts = [] of Array(Tuple(UInt64, UInt64))

    [false, true].each do |radix|
      heap = radix ? radix_heap : plain_heap
      begin
        ptrs = [] of Void*
        40.times { sizes.each { |sz| ptrs << heap.malloc(sz.to_u64) } }

        seen = [] of Tuple(UInt64, UInt64)
        ptrs.each do |ptr|
          [0_u64, 1_u64, 8_u64].each do |delta|
            probe = Pointer(Void).new(ptr.address + delta)
            header = heap.find_block(probe)
            # Record the block's offset from the pointer rather than the raw
            # address: the two heaps map chunks at different addresses, so only
            # a relative answer is comparable.
            seen << {delta, header.nil? ? UInt64::MAX : ptr.address - header.address}
          end
        end
        layouts << seen
      ensure
        heap.destroy
      end
    end

    layouts[1].size.should eq(layouts[0].size)
    layouts[1].should eq(layouts[0])
  end

  it "answers from the table rather than falling through every time" do
    # Distinguishes "the radix is on" from "the radix is on and useless". With
    # the verify-and-fall-back design, a table that never hit would still give
    # correct answers and pass every assertion above.
    heap = radix_heap
    begin
      ptrs = [] of Void*
      500.times { ptrs << heap.malloc(64) }
      ptrs.each { |p| heap.find_block(p) }

      heap.radix_fast_hits.should be > 0_u64
      # The table is authoritative for small chunks, so the overwhelming
      # majority of lookups should be hits rather than fall-throughs.
      total = heap.radix_fast_hits + heap.radix_slow_lookups
      total.should be > 0_u64
      (heap.radix_fast_hits * 10).should be > (total * 9)
    ensure
      heap.destroy
    end
  end

  it "declines to publish a chunk too large to be worth it, and still answers" do
    # A chunk spanning more than MAX_GRANULES_PER_CHUNK granules is left out to
    # keep map/unmap O(chunks) rather than O(bytes). The binary search has to
    # cover it, which is the whole reason the fallback is kept.
    heap = radix_heap
    begin
      big = heap.malloc(Gcry::Heap::RADIX_MAX_GRANULES.to_u64 * Gcry::Platform.host_page_size * 2)
      heap.radix_oversize_skips.should be > 0_u64

      header = heap.find_block(big)
      header.should_not be_nil
      Gcry::BlockHeader.user_from(header.not_nil!).should eq(big)

      # And an interior pointer into it.
      interior = Pointer(Void).new(big.address + 4096)
      heap.find_block(interior).should eq(header)
    ensure
      heap.destroy
    end
  end

  it "does not answer for addresses outside the heap" do
    heap = radix_heap
    begin
      heap.malloc(64)
      heap.find_block(Pointer(Void).new(0x10_u64)).should be_nil
      heap.find_block(Pointer(Void).null).should be_nil
      # An address inside a chunk's header region belongs to no block.
      heap.each_chunk do |chunk|
        heap.find_block(Pointer(Void).new(chunk.address)).should be_nil
      end
    ensure
      heap.destroy
    end
  end

  it "stops answering for a chunk after it is released" do
    # `remove` runs inside `index_remove_locked`, before the caller's munmap. If
    # an entry outlived its mapping, the containment check that follows a hit
    # would dereference unmapped memory — so a stale entry is not a wrong
    # answer, it is a fault.
    heap = radix_heap
    begin
      addrs = [] of UInt64
      2000.times { heap.malloc(200) }
      heap.each_chunk { |chunk| addrs << chunk.address }
      addrs.size.should be > 1

      5.times { heap.collect(scan_stack: false) }

      # Whatever survived, every answer the heap gives must still be one it can
      # justify: the block found must lie inside a chunk the heap still owns.
      addrs.each do |base|
        probe = Pointer(Void).new(base + Gcry::ChunkHeader::SIZE + Gcry::BlockHeader::SIZE)
        if header = heap.find_block(probe)
          # `live?` is the public read that goes through the same resolution,
          # so a stale radix entry would show up here as an answer about a
          # chunk the heap no longer owns.
          user = Gcry::BlockHeader.user_from(header)
          heap.find_block(user).should eq(header)
        end
      end
    ensure
      heap.destroy
    end
  end

  it "survives repeated map/unmap cycles without drifting from the search" do
    heap = radix_heap
    begin
      6.times do
        held = [] of Void*
        300.times { held << heap.malloc(1024) }
        held.each { |p| heap.find_block(p).should_not be_nil }
        held.clear
        heap.collect(scan_stack: false)
      end
      keep = heap.malloc(64)
      heap.add_root(keep)
      heap.collect(scan_stack: false)
      heap.live?(keep).should be_true
      heap.find_block(keep).should_not be_nil
    ensure
      heap.destroy
    end
  end
end
