# Mark phase: candidates, object scan, nursery remembered-set helpers.

module Gcry
  class Heap
    # Heap-scan / explicit roots: follow interiors (Array#shift advances @buffer
    # into its allocation). Never apply type_id_gate (raw buffers OK).
    private def mark_candidate(pointer : Void*) : Nil
      mark_impl(pointer, gate_type_id: false, base_only: false)
    end

    # Ambient roots (stack / static / fiber stacks): optional type_id gate;
    # base-pointer-only unless GCRY_INTERIOR=1 (cuts false retention).
    private def mark_root_candidate(pointer : Void*) : Nil
      mark_impl(pointer, gate_type_id: @type_id_gate, base_only: !@allow_interior_pointers)
    end

    private def mark_impl(pointer : Void*, gate_type_id : Bool, base_only : Bool) : Nil
      if @mark_parallel
        @mark_lock.lock
        begin
          mark_impl_unlocked(pointer, gate_type_id, base_only)
        ensure
          @mark_lock.unlock
        end
      else
        mark_impl_unlocked(pointer, gate_type_id, base_only)
      end
    end

    private def mark_impl_unlocked(pointer : Void*, gate_type_id : Bool, base_only : Bool) : Nil
      addr = pointer.address
      return if @heap_max == 0 || addr < @heap_min || addr >= @heap_max
      # Crystal pointers are word-aligned; reject interior/misaligned false hits fast.
      return if (addr & (sizeof(Void*).to_u64 - 1)) != 0

      header = find_object(pointer)
      return unless header
      return if BlockHeader.free?(header)

      if base_only
        # Object-base only on ambient roots: interiors into String/Array buffers
        # inflate false retention. Heap marks must allow interiors (shift).
        return if addr != BlockHeader.user_from(header).address
      end

      if gate_type_id && !type_id_plausible?(header)
        @type_id_root_rejects += 1
        note_false_root(addr)
        return
      end

      return if BlockHeader.marked?(header)
      if @minor_only && !BlockHeader.nursery?(header)
        return
      end

      BlockHeader.set_mark(header)
      @mark_stack.push(header)
    end

    # Keep allocation alive without scanning its payload (integer / index buffers).
    # Always allow interiors — Array(UInt8)#shift stores an interior @buffer.
    private def mark_noscan(pointer : Void*) : Nil
      if @mark_parallel
        @mark_lock.lock
        begin
          mark_noscan_unlocked(pointer)
        ensure
          @mark_lock.unlock
        end
      else
        mark_noscan_unlocked(pointer)
      end
    end

    private def mark_noscan_unlocked(pointer : Void*) : Nil
      addr = pointer.address
      return if @heap_max == 0 || addr < @heap_min || addr >= @heap_max
      return if (addr & (sizeof(Void*).to_u64 - 1)) != 0

      header = find_object(pointer)
      return unless header
      return if BlockHeader.free?(header)

      return if BlockHeader.marked?(header)
      if @minor_only && !BlockHeader.nursery?(header)
        return
      end

      BlockHeader.set_mark(header)
    end

    # Crystal Reference payloads start with type_id (Int32). Reject if that
    # 32-bit word looks like the high half of a pointer / absurd id.
    private def type_id_plausible?(header : BlockHeader*) : Bool
      return true if BlockHeader.atomic?(header)
      size = header.value.size.to_u64
      return true if size < 4

      tid = BlockHeader.user_from(header).as(Int32*).value
      return false if tid < 0
      # Crystal type ids are dense small integers, not pointer-sized values.
      return false if tid > 1_000_000
      true
    end

    private def mark_loop : Nil
      until @mark_stack.empty?
        header = @mark_stack.pop
        scan_object(header)
      end
    end

    private def mark_loop_budget(work_units : Int32) : Nil
      units = 0
      while units < work_units && !@mark_stack.empty?
        header = @mark_stack.pop
        scan_object(header)
        units += 1
      end
    end

    private def scan_object(header : BlockHeader*) : Nil
      return if BlockHeader.atomic?(header)

      user = BlockHeader.user_from(header).as(UInt8*)
      size = clamped_scan_size(header, user)
      return if size == 0

      if @layout_precise && size >= 4
        tid = user.as(Int32*).value
        if (entry = Layout.entry_for(tid))
          if entry.alloc_size == 0 || size == entry.alloc_size.to_u64
            @layout_precise_scans += 1
            if entry.hash?
              scan_hash_object(user, size, entry)
            else
              entry.scan_offsets.each do |off|
                next if off.to_u64 + sizeof(Void*).to_u64 > size
                slot = Pointer(Void*).new(user.address + off.to_u64)
                mark_candidate(slot.value)
              end
              entry.noscan_offsets.each do |off|
                next if off.to_u64 + sizeof(Void*).to_u64 > size
                slot = Pointer(Void*).new(user.address + off.to_u64)
                mark_noscan(slot.value)
              end
            end
            return
          end
        end
      end

      @layout_conservative_scans += 1
      word = sizeof(Void*).to_u64
      words = size // word
      cursor = user.as(UInt64*)
      words.times do |i|
        mark_candidate(Pointer(Void).new(cursor[i]))
      end
    end

    # Precise Hash: keep @indices/@entries blobs alive without scanning them as
    # pointer arrays; walk Entry slots and mark key/value only.
    private def scan_hash_object(user : UInt8*, size : UInt64, entry : Layout::Entry) : Nil
      entry.scan_offsets.each do |off|
        next if off.to_u64 + sizeof(Void*).to_u64 > size
        slot = Pointer(Void*).new(user.address + off.to_u64)
        mark_candidate(slot.value)
      end

      entry.noscan_offsets.each do |off|
        next if off.to_u64 + sizeof(Void*).to_u64 > size
        slot = Pointer(Void*).new(user.address + off.to_u64)
        mark_noscan(slot.value)
      end

      entries_off = entry.hash_entries_off.to_u64
      pow2_off = entry.hash_pow2_off.to_u64
      stride = entry.hash_entry_stride.to_u64
      return if stride == 0
      return if entries_off + sizeof(Void*).to_u64 > size
      return if pow2_off + 1 > size

      entries = Pointer(Void*).new(user.address + entries_off).value
      return if entries.null?

      pow2 = Pointer(UInt8).new(user.address + pow2_off).value
      # Crystal: indices_size = 1 << pow2; entries_size = indices_size // 2
      return if pow2 >= 63
      entries_size = (1_u64 << pow2) // 2
      return if entries_size == 0 || entries_size > 1_000_000_u64

      key_off = entry.hash_key_off.to_u64
      value_off = entry.hash_value_off.to_u64
      value_mode = entry.hash_value_mode
      value_bytes = entry.hash_value_bytes.to_u64
      base = entries.as(UInt8*)

      i = 0_u64
      while i < entries_size
        slot = base + (i * stride)
        # Entry.@hash == 0 ⇒ deleted (Crystal Hash).
        hash_word = slot.as(UInt32*).value
        if hash_word != 0_u32
          if key_off != 0
            mark_candidate(Pointer(Void*).new(slot.address + key_off).value)
          end
          case value_mode
          when Layout::VALUE_MODE_REF
            mark_candidate(Pointer(Void*).new(slot.address + value_off).value)
          when Layout::VALUE_MODE_WORDS
            w = 0_u64
            while w + sizeof(Void*).to_u64 <= value_bytes
              mark_candidate(Pointer(Void*).new(slot.address + value_off + w).value)
              w += sizeof(Void*).to_u64
            end
          end
        end
        i += 1
      end
    end

    # Corrupted header.size must not walk past the mapped chunk (SIGSEGV).
    private def clamped_scan_size(header : BlockHeader*, user : UInt8*) : UInt64
      size = header.value.size.to_u64
      chunk = chunk_containing(header.address)
      return 0_u64 unless chunk

      max = if ChunkHeader.large?(chunk)
              end_addr = ChunkHeader.data_end(chunk).address
              end_addr > user.address ? (end_addr - user.address) : 0_u64
            else
              class_index = chunk.value.size_class.to_i32
              return 0_u64 if class_index < 0 || class_index >= SIZE_CLASS_COUNT
              SizeClasses.payload(class_index).to_u64
            end
      size > max ? max : size
    end

    private def scan_old_for_nursery_pointers : Nil
      # Official remembered set: soft-dirty or mprotect dirty pages.
      if scan_dirty_pages_for_pointers(nursery_only: true)
        return
      end

      # Fallback: full conservative old→young object walk.
      each_chunk do |chunk|
        if ChunkHeader.large?(chunk)
          header = ChunkHeader.data_start(chunk).as(BlockHeader*)
          next if BlockHeader.free?(header)
          scan_object_for_nursery(header)
        else
          each_block(chunk) do |header|
            next if BlockHeader.free?(header)
            next if BlockHeader.nursery?(header)
            scan_object_for_nursery(header)
          end
        end
      end
    end

    # Word-scan a mapped range for pointers into nursery objects (dirty pages).
    private def scan_range_for_nursery_pointers(low : Void*, high : Void*) : Nil
      scan_range_for_barrier_pointers(low, high, true)
    end

    # Legacy name kept for destroy / docs; delegates to the page-barrier layer.
    private def arm_soft_dirty_after_collect : Nil
      arm_page_barrier_after_collect
    end

    # Confirm the kernel sets soft-dirty after a store (broken on some WSL builds).
    # Uses a dedicated anonymous page — never touch the managed heap.
    protected def soft_dirty_tracks_writes? : Bool
      page = LibC.mmap(
        Pointer(Void).null,
        LibC::SizeT.new(Platform::PAGE_SIZE),
        LibC::PROT_READ | LibC::PROT_WRITE,
        LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS,
        -1,
        0,
      )
      return false if Gcry.mmap_failed?(page)

      begin
        addr = page.address
        page.as(UInt8*).value = 1_u8
        dirty = false
        ok = Platform.each_dirty_page(addr, addr + Platform::PAGE_SIZE) do |_|
          dirty = true
        end
        ok && dirty
      ensure
        LibC.munmap(page, LibC::SizeT.new(Platform::PAGE_SIZE))
      end
    end

    private def scan_object_for_nursery(header : BlockHeader*) : Nil
      return if BlockHeader.atomic?(header)
      user = BlockHeader.user_from(header).as(UInt8*)
      size = clamped_scan_size(header, user)
      return if size == 0

      word = sizeof(Void*).to_u64
      words = size // word
      cursor = user.as(UInt64*)
      words.times do |i|
        cand = Pointer(Void).new(cursor[i])
        next unless (h = find_object(cand))
        next unless BlockHeader.nursery?(h)
        mark_candidate(cand)
      end
    end

    private def clear_all_marks : Nil
      each_chunk do |chunk|
        each_block_or_large(chunk) do |header|
          next if BlockHeader.free?(header)
          BlockHeader.clear_mark(header)
        end
      end
    end

    # Minor GC: reset nursery mark bits only.
    private def clear_nursery_marks : Nil
      each_chunk do |chunk|
        next unless ChunkHeader.nursery?(chunk)
        each_block(chunk) do |header|
          next if BlockHeader.free?(header)
          BlockHeader.clear_mark(header)
        end
      end
    end

    private def each_block_or_large(chunk : ChunkHeader*, & : BlockHeader* ->) : Nil
      if ChunkHeader.large?(chunk)
        yield ChunkHeader.data_start(chunk).as(BlockHeader*)
      else
        each_block(chunk) { |h| yield h }
      end
    end

    # After mark, before sweep. Allocation-free (no Crystal Proc/closure).
    private def enqueue_unreachable_finalizers : Nil
      i = 0
      while i < @finalizers.entry_count
        if unmarked_live_object?(@finalizers.entry_object_at(i))
          @finalizers.queue_and_remove_entry_at(i)
        else
          i += 1
        end
      end

      i = 0
      while i < @finalizers.link_count
        if unmarked_live_object?(@finalizers.link_object_at(i))
          @finalizers.clear_and_remove_link_at(i)
        else
          i += 1
        end
      end
    end

    private def unmarked_live_object?(obj : Void*) : Bool
      return false if obj.null?
      header = find_object(obj)
      return false unless header
      return false if BlockHeader.free?(header)
      # During generational minor, old objects are intentionally unmarked.
      # Only nursery deaths may enqueue finalizers / clear WeakRef links.
      return false if @minor_only && !BlockHeader.nursery?(header)
      !BlockHeader.marked?(header)
    end
  end
end
