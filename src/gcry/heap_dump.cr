# Heap dump — live-object NDJSON for leak hunting (Phase 7.2).
#
# Debug-only: walking a multi-GB heap may take seconds. Prefer after a collect
# when the live set is stable.
#
#   Gcry.dump_heap(io)           # NDJSON lines
#   Gcry.dump_heap_addresses     # Set of live user pointers (for diff)
#   Gcry.live_attr_json          # size-class + top type_id summary (attribution)

module Gcry
  # Post-collect live-set attribution: aggregate USED blocks by size class and
  # (plausible) type_id. Research aid for dense-live RSS (acik ~380 MiB) —
  # does not prove false roots; pairs with first-mark counters when
  # GCRY_LIVE_ATTR=1. Prefer after dual GC.collect so the live set is stable.
  def self.live_attr_json(heap : Heap = default_heap, top_n : Int32 = 40) : String
    Observability.json_live_attr(heap, top_n)
  end

  # Write one NDJSON object per live block to *io*.
  # Returns the number of live objects written.
  # Warning: dumping heaps ≥ ~1 GiB may take > 10s.
  def self.dump_heap(io : IO, heap : Heap = default_heap) : UInt64
    count = 0_u64
    heap.each_chunk do |chunk|
      if ChunkHeader.large?(chunk)
        header = ChunkHeader.data_start(chunk).as(BlockHeader*)
        next if BlockHeader.free?(header)
        write_dump_line(io, header, heap)
        count += 1
      else
        class_index = chunk.value.size_class.to_i32
        next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
        payload = SizeClasses.payload(class_index)
        block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
        cursor = ChunkHeader.data_start(chunk).as(UInt8*)
        limit = ChunkHeader.data_end(chunk).as(UInt8*)
        while (cursor + block_bytes) <= limit
          header = cursor.as(BlockHeader*)
          unless BlockHeader.free?(header)
            write_dump_line(io, header, heap)
            count += 1
          end
          cursor += block_bytes
        end
      end
    end
    count
  end

  # Collect live user-pointer addresses (allocation-light for small heaps).
  def self.dump_heap_addresses(heap : Heap = default_heap) : Set(UInt64)
    addrs = Set(UInt64).new
    heap.each_chunk do |chunk|
      if ChunkHeader.large?(chunk)
        header = ChunkHeader.data_start(chunk).as(BlockHeader*)
        next if BlockHeader.free?(header)
        addrs << BlockHeader.user_from(header).address
      else
        class_index = chunk.value.size_class.to_i32
        next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
        payload = SizeClasses.payload(class_index)
        block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
        cursor = ChunkHeader.data_start(chunk).as(UInt8*)
        limit = ChunkHeader.data_end(chunk).as(UInt8*)
        while (cursor + block_bytes) <= limit
          header = cursor.as(BlockHeader*)
          unless BlockHeader.free?(header)
            addrs << BlockHeader.user_from(header).address
          end
          cursor += block_bytes
        end
      end
    end
    addrs
  end

  # Addresses present in *after* but not *before* (new survivors / growth).
  def self.heap_dump_new(before : Set(UInt64), after : Set(UInt64)) : Set(UInt64)
    after - before
  end

  # Addresses present in *before* but not *after* (reclaimed).
  def self.heap_dump_gone(before : Set(UInt64), after : Set(UInt64)) : Set(UInt64)
    before - after
  end

  private def self.write_dump_line(io : IO, header : BlockHeader*, heap : Heap) : Nil
    user = BlockHeader.user_from(header)
    size = header.value.size.to_u64
    type_id = 0_i32
    # Crystal objects store type_id as Int32 at the start of the payload when
    # the block is large enough; raw buffers may contain garbage — still report.
    if size >= 4
      type_id = user.as(Int32*).value
    end
    # Through the heap: under GCRY_BITMAP=1 the header generation is not
    # what the sweep reads, and a dump that says "marked" about an object
    # the collector considers garbage is a wrong answer, not a missing one.
    marked = heap.marked_for_report?(header)
    atomic = BlockHeader.atomic?(header)
    nursery = BlockHeader.nursery?(header)
    io << "{\"addr\":\"0x" << user.address.to_s(16)
    io << "\",\"size\":" << size
    io << ",\"type_id\":" << type_id
    io << ",\"marked\":" << marked
    io << ",\"atomic\":" << atomic
    io << ",\"nursery\":" << nursery
    io << "}\n"
  end
end
