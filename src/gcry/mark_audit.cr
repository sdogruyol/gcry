# Did the mark reach everything a marked object points at?
#
# The 2026-08-16 use-after-free hunt reached a contradiction it could not settle
# by reading code. The crash report says the freed block is the live execution
# context's stack-pool `Deque(Fiber::Stack)` buffer, that the deque's
# `@capacity` matches that block exactly, and — since `Flags::SWEPT` —
# that the **sweep** freed it, i.e. the collector decided it was garbage. But
# rooting the deque explicitly does not change the crash rate, and a root marks
# the object *and* scans its payload, so `@buffer` should have been marked.
# Every heuristic that could drop the edge (`type_id_gate`, interior pointers,
# auto layouts) was A/B'd and none of them moves the rate either.
#
# One of those statements is false, and no amount of reading has said which.
# So ask the collector, in the one window where the answer exists: after
# `mark_loop`, before `sweep`. At that instant a marked object whose payload
# points at the base of an **unmarked, used** block is a missed edge — the
# sweep is about to free something reachable — and the audit names the parent,
# the offset, and the child.
#
# `GCRY_MARK_AUDIT=1`. Off by default: it is O(live heap) inside the pause, and
# it is a debugging instrument, not a safety net. It reports; it does not fix.
#
# Two deliberate limits, both to keep false positives from burying a real hit:
#
#   - **Base pointers only.** A word is a candidate edge only if it equals a
#     block's user address exactly. Interior pointers into buffers are how
#     `Array#shift` works and are followed by the real mark, but a conservative
#     interior hit from a garbage word is far more likely than a base one.
#   - **ATOMIC parents are skipped**, exactly as `scan_object` skips them: the
#     collector never reads those payloads, so a pointer-shaped word in one is
#     not an edge.
#
# A hit is not automatically a defect: the parent's word may be stale data that
# happens to equal a live block's base. That is why the report prints both
# type_ids and the offset — enough to tell "`Deque` at +16" from "a byte buffer
# at +904".

module Gcry
  class Heap
    # `GCRY_MARK_AUDIT=1`. See src/gcry/mark_audit.cr.
    property mark_audit : Bool = false

    # `GCRY_MARK_AUDIT_ALL=1`: walk **every** used block as a parent, not only
    # the marked ones, and report the parent's mark state with each edge into a
    # dying block.
    #
    # The default walk asks "does anything that survives point at something
    # about to be freed?" and answered *no* in six crashing runs — while the
    # crash report showed a live `Deque` pointing at exactly such a block. Both
    # cannot be complete, and the gap is this filter: an unmarked parent's edges
    # are never examined, so the audit cannot see the very edge in question if
    # the `Deque` was itself unmarked
    # (`bench/log/linux/2026-08-16-uaf-mark-complete/FINDINGS.md`).
    property mark_audit_all_parents : Bool = false

    # Edges from an **unmarked** parent into a dying block. Garbage pointing at
    # garbage is ordinary and expected; what makes it worth counting is that the
    # `Deque` in the crash reports is alive afterwards, so finding it here would
    # say it was dying at the collection that freed its buffer.
    getter mark_audit_dying_edges : UInt64 = 0_u64

    # Missed edges seen across the process, cumulative. On `/gc-stats` so a run
    # that ends without a crash still says whether the mark was complete.
    getter mark_audit_misses : UInt64 = 0_u64
    getter mark_audit_edges : UInt64 = 0_u64

    # Per-collection report cap. A single missed edge is the finding; four
    # hundred of them are the same finding printed four hundred times, inside a
    # stopped world.
    MARK_AUDIT_REPORT_LIMIT = 4

    # `GCRY_DYING_REGISTER_AUDIT=1`: for each block the sweep is about to free,
    # ask whether its address sits in a **suspended thread's captured GP
    # registers**.
    #
    # This is the last place not yet looked. The all-parents audit showed that
    # when the buffer dies, nothing in the used heap points at it; the crash
    # report shows a running fiber's stack holding it afterwards. So the value
    # crosses the collection somewhere the mark does not consult — and the
    # registers of suspended threads are consulted (v0.19.0 closed the two
    # platforms that returned nothing), which makes "is it there?" a question
    # with two informative answers. In the registers ⇒ the register scan is
    # dropping it and this is root coverage. Not there ⇒ the value lives
    # somewhere gcry has never looked.
    property dying_register_audit : Bool = false

    getter dying_register_hits : UInt64 = 0_u64
    getter dying_blocks_checked : UInt64 = 0_u64

    # Only the size band the crashes come from (`Deque(Fiber::Stack)`
    # capacities), so the walk stays bounded inside the pause.
    DYING_AUDIT_MIN_SIZE = 384_u32

    private def audit_dying_registers : Nil
      checked = 0_u64
      hits = 0_u64
      reported = 0
      each_chunk do |chunk|
        next if ChunkHeader.dormant?(chunk)
        next if ChunkHeader.large?(chunk)
        class_index = chunk.value.size_class.to_i32!
        next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
        payload = SizeClasses.payload(class_index)
        next if payload < DYING_AUDIT_MIN_SIZE
        block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
        cursor = ChunkHeader.data_start(chunk).as(UInt8*)
        limit = ChunkHeader.data_end(chunk).as(UInt8*)
        while (cursor + block_bytes) <= limit
          header = cursor.as(BlockHeader*)
          cursor += block_bytes
          next if BlockHeader.free?(header)
          next if heap_marked?(header)
          # About to be freed.
          checked &+= 1
          addr = BlockHeader.user_from(header).address
          found = false
          Thread.unsafe_each do |thread|
            Platform.each_thread_greg(thread.to_unsafe) do |value|
              found = true if value.address == addr
            end
          end
          next unless found
          hits &+= 1
          next unless reported < MARK_AUDIT_REPORT_LIMIT
          reported += 1
          buf = uninitialized UInt8[512]
          len = 0
          len = RawOut.append(buf.to_unsafe, len,
            "gcry: dying-register audit — block 0x")
          len = RawOut.append_hex(buf.to_unsafe, len, addr)
          len = RawOut.append(buf.to_unsafe, len, " size ")
          len = RawOut.append_u64(buf.to_unsafe, len, header.value.size.to_u64)
          len = RawOut.append(buf.to_unsafe, len,
            " is about to be swept and its address is in a suspended thread's registers. collection ")
          len = RawOut.append_u64(buf.to_unsafe, len, @collections)
          len = RawOut.append(buf.to_unsafe, len, "\n")
          RawOut.flush(buf.to_unsafe, len)
        end
      end
      @dying_blocks_checked &+= checked
      @dying_register_hits &+= hits
    end

    # Runs after `mark_loop` and before `sweep`, with the world stopped, so the
    # heap is quiescent and "marked" is final.
    protected def run_mark_audit : Nil
      audit_dying_registers if @dying_register_audit
      reported = 0
      edges = 0_u64
      misses = 0_u64

      each_chunk do |chunk|
        next if ChunkHeader.dormant?(chunk)
        if ChunkHeader.large?(chunk)
          header = ChunkHeader.data_start(chunk).as(BlockHeader*)
          next if BlockHeader.free?(header)
          next unless heap_marked?(header) || @mark_audit_all_parents
          reported = audit_block(header, pointerof(edges), pointerof(misses), reported)
          next
        end

        class_index = chunk.value.size_class.to_i32!
        next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
        payload = SizeClasses.payload(class_index)
        block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
        cursor = ChunkHeader.data_start(chunk).as(UInt8*)
        limit = ChunkHeader.data_end(chunk).as(UInt8*)
        while (cursor + block_bytes) <= limit
          header = cursor.as(BlockHeader*)
          if !BlockHeader.free?(header) && (heap_marked?(header) || @mark_audit_all_parents)
            reported = audit_block(header, pointerof(edges), pointerof(misses), reported)
          end
          cursor += block_bytes
        end
      end

      @mark_audit_edges &+= edges
      @mark_audit_misses &+= misses
      return if misses == 0

      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: mark audit — ")
      len = RawOut.append_u64(buf.to_unsafe, len, misses)
      len = RawOut.append(buf.to_unsafe, len, " missed edge(s) of ")
      len = RawOut.append_u64(buf.to_unsafe, len, edges)
      len = RawOut.append(buf.to_unsafe, len,
        " base edges from marked objects; the sweep is about to free memory something points at. " \
        "collection ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # Counters go through pointers rather than returns because this is called
    # from a loop that must not allocate a tuple inside the stopped world.
    private def audit_block(header : BlockHeader*, edges : UInt64*, misses : UInt64*,
                            reported : Int32) : Int32
      return reported if BlockHeader.atomic?(header)
      size = header.value.size.to_u64
      return reported if size < sizeof(UInt64)
      base = BlockHeader.user_from(header).address
      words = size // sizeof(UInt64)
      i = 0_u64
      while i < words
        w = Pointer(UInt64).new(base &+ i &* sizeof(UInt64)).value
        i &+= 1
        next if w == 0
        next if w < @heap_min || w >= @heap_max
        next if (w & (sizeof(Void*).to_u64 - 1)) != 0
        child = find_block(Pointer(Void).new(w))
        next unless child
        # Base pointers only — see the file header.
        next unless BlockHeader.user_from(child).address == w
        next if BlockHeader.free?(child)
        edges.value &+= 1
        next if heap_marked?(child)
        parent_marked = heap_marked?(header)
        if parent_marked
          misses.value &+= 1
        else
          # Garbage pointing at garbage. Counted separately so it cannot inflate
          # the miss count, and reported because *which* garbage matters: the
          # crash's holder is a `Deque` that is alive afterwards.
          @mark_audit_dying_edges &+= 1
        end
        next unless reported < MARK_AUDIT_REPORT_LIMIT
        reported += 1
        report_missed_edge(header, base, (i &- 1) &* sizeof(UInt64), child, w, parent_marked)
      end
      reported
    end

    private def report_missed_edge(parent : BlockHeader*, parent_base : UInt64, offset : UInt64,
                                   child : BlockHeader*, child_addr : UInt64,
                                   parent_marked : Bool = true) : Nil
      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len,
        parent_marked ? "gcry: mark audit — marked block 0x" : "gcry: mark audit — UNMARKED (dying) block 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, parent_base)
      len = RawOut.append(buf.to_unsafe, len, " type_id ")
      len = RawOut.append_u64(buf.to_unsafe, len, Pointer(UInt32).new(parent_base).value.to_u64)
      len = RawOut.append(buf.to_unsafe, len, " size ")
      len = RawOut.append_u64(buf.to_unsafe, len, parent.value.size.to_u64)
      len = RawOut.append(buf.to_unsafe, len, " points at +")
      len = RawOut.append_u64(buf.to_unsafe, len, offset)
      len = RawOut.append(buf.to_unsafe, len, " to UNMARKED block 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, child_addr)
      len = RawOut.append(buf.to_unsafe, len, " size ")
      len = RawOut.append_u64(buf.to_unsafe, len, child.value.size.to_u64)
      len = RawOut.append(buf.to_unsafe, len, " flags 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, child.value.flags.to_u64)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end
  end
end
