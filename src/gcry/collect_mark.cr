# Mark phase: candidates, object scan, nursery remembered-set helpers.

module Gcry
  class Heap
    # Ambient-root source tag for per-source reject counters. Distinguishes
    # fiber/mutator stacks, BSS/data segments, and TLS (thread) so the
    # false-positive root cause can be attributed. Cheap enum (1 byte) — passed
    # through mark_root_candidate → mark_impl → mark_impl_unlocked; the case
    # only runs on the type_id gate reject path, so the hot path is unchanged.
    private enum RootSource
      Stack
      Static
      Thread
    end

    # Heap-scan / explicit roots: follow interiors (Array#shift advances @buffer
    # into its allocation). Never apply type_id_gate (raw buffers OK).
    private def mark_candidate(pointer : Void*) : Nil
      mark_impl(pointer, gate_type_id: false, base_only: false, source: RootSource::Stack)
    end

    # Ambient roots (stack / static / fiber stacks): optional type_id gate;
    # base-pointer-only unless GCRY_INTERIOR=1 (cuts false retention).
    private def mark_root_candidate(pointer : Void*, source : RootSource = RootSource::Stack) : Nil
      mark_impl(pointer, gate_type_id: @type_id_gate, base_only: !@allow_interior_pointers, source: source)
    end

    # add_root / collect(roots:) / realloc pin — never type_id_gate (raw Hash
    # @entries / Array @buffer have no Crystal type_id). Interior policy matches
    # ambient roots so allow_interior_pointers still applies.
    private def mark_explicit_root(pointer : Void*) : Nil
      mark_impl(pointer, gate_type_id: false, base_only: !@allow_interior_pointers, source: RootSource::Stack)
    end

    private def mark_impl(pointer : Void*, gate_type_id : Bool, base_only : Bool, source : RootSource) : Nil
      if @mark_parallel
        @mark_lock.lock
        begin
          mark_impl_unlocked(pointer, gate_type_id, base_only, source)
        ensure
          @mark_lock.unlock
        end
      else
        mark_impl_unlocked(pointer, gate_type_id, base_only, source)
      end
    end

    private def mark_impl_unlocked(pointer : Void*, gate_type_id : Bool, base_only : Bool, source : RootSource) : Nil
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
        case source
        when RootSource::Stack  then @type_id_stack_rejects += 1
        when RootSource::Static then @type_id_static_rejects += 1
        when RootSource::Thread then @type_id_thread_rejects += 1
        end
        note_false_root(addr)
        return
      end

      return if heap_marked?(header)
      if @minor_only && !BlockHeader.nursery?(header)
        return
      end

      heap_set_mark(header)
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

      return if heap_marked?(header)
      if @minor_only && !BlockHeader.nursery?(header)
        return
      end

      heap_set_mark(header)
    end

    # Crystal Reference payloads start with type_id (Int32). Reject if that
    # 32-bit word looks like the high half of a pointer / absurd id.
    private def type_id_plausible?(header : BlockHeader*) : Bool
      return true if BlockHeader.atomic?(header)
      size = header.value.size.to_u64
      return true if size < 4

      tid = BlockHeader.user_from(header).as(Int32*).value
      # Crystal type ids are dense positive integers (0 is not a real instance id;
      # a leading zero word is typical of Pointer(T) buffers / empty slots).
      return false if tid <= 0
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
          size_match = entry.alloc_size == 0 || size == entry.alloc_size.to_u64
          if size_match && entry.precise_fields?
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
          elsif size_match && entry.scan_cap > 0
            # Size-cap only when this really is the registered type (alloc_size
            # matches). Applying scan_cap on size mismatch was unsound: raw
            # buffers whose first Int32 randomly equals a registered type_id
            # stopped after instance_sizeof bytes and missed the rest → UAF
            # (acikturkiye; fixed by requiring size_match here).
            @layout_conservative_scans += 1
            cap = entry.scan_cap.to_u64
            limit = size < cap ? size : cap
            word = sizeof(Void*).to_u64
            words = limit // word
            cursor = user.as(UInt64*)
            words.times do |i|
              mark_impl(Pointer(Void).new(cursor[i]), gate_type_id: false, base_only: false, source: RootSource::Stack)
            end
            return
          elsif size_match
            # Leaf / value-only type: nothing to mark in the body.
            @layout_precise_scans += 1
            return
          end
          # size mismatch: ignore the layout entry (likely a raw buffer whose
          # leading word collided with a Crystal type_id) → full conservative.
        end
      end

      @layout_conservative_scans += 1
      # Raw buffers (no Crystal type_id): object-base only — cuts interior false
      # hits from JSON/bytes. Typed References keep interiors so Array#shift and
      # layout-miss types with mid-object pointers stay correct.
      base_only = size >= 4 && !type_id_plausible?(header)
      word = sizeof(Void*).to_u64
      words = size // word
      cursor = user.as(UInt64*)
      words.times do |i|
        mark_impl(Pointer(Void).new(cursor[i]), gate_type_id: false, base_only: base_only, source: RootSource::Stack)
      end
    end

    # Precise Hash: keep @indices/@entries blobs alive without scanning them as
    # pointer arrays; walk Entry slots and mark key/value only.
    # Live range is Crystal `@size + @deleted_count` (entries_size), NOT
    # entries_capacity from `@indices_size_pow2` — capacity slots after realloc
    # are uninitialized and must not be treated as Entry records.
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

      # Proc? @block is multi-word (function pointer + closure data).
      block_off = entry.hash_block_off.to_u64
      block_bytes = entry.hash_block_bytes.to_u64
      if block_bytes > 0 && block_off + block_bytes <= size
        w = 0_u64
        while w + sizeof(Void*).to_u64 <= block_bytes
          mark_candidate(Pointer(Void*).new(user.address + block_off + w).value)
          w += sizeof(Void*).to_u64
        end
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
      # Crystal: indices_size = 1 << pow2; entries_capacity = indices_size // 2
      return if pow2 >= 63
      capacity = (1_u64 << pow2) // 2
      return if capacity == 0 || capacity > 1_000_000_u64

      # Crystal entries_size == @size + @deleted_count (not capacity).
      used = capacity
      size_off = entry.hash_size_off.to_u64
      deleted_off = entry.hash_deleted_off.to_u64
      if size_off + 4 <= size && deleted_off + 4 <= size
        live_size = Pointer(Int32).new(user.address + size_off).value
        deleted = Pointer(Int32).new(user.address + deleted_off).value
        if live_size >= 0 && deleted >= 0
          sum = live_size.to_i64 + deleted.to_i64
          if sum >= 0 && sum.to_u64 <= capacity
            used = sum.to_u64
          end
        end
      end

      key_off = entry.hash_key_off.to_u64
      key_bytes = entry.hash_key_bytes.to_u64
      value_off = entry.hash_value_off.to_u64
      value_mode = entry.hash_value_mode
      value_bytes = entry.hash_value_bytes.to_u64
      base = entries.as(UInt8*)

      i = 0_u64
      while i < used
        slot = base + (i * stride)
        # Entry.@hash == 0 ⇒ deleted (Crystal Hash).
        hash_word = slot.as(UInt32*).value
        if hash_word != 0_u32
          if key_bytes > 0
            w = 0_u64
            while w + sizeof(Void*).to_u64 <= key_bytes
              mark_candidate(Pointer(Void*).new(slot.address + key_off + w).value)
              w += sizeof(Void*).to_u64
            end
          elsif key_off != 0
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
      # Soft-dirty/mprotect can *help* mark from dirty pages, but must not
      # replace the full old→young walk: WSL soft-dirty false-negatives under
      # release HTTP left nursery Hash keys unmarked → SEGV.
      scan_dirty_pages_for_pointers(nursery_only: true)

      each_chunk do |chunk|
        if ChunkHeader.large?(chunk)
          header = ChunkHeader.data_start(chunk).as(BlockHeader*)
          next if BlockHeader.free?(header)
          next if BlockHeader.nursery?(header)
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

      # Old Hash objects store keys/values in a separate @entries blob. Word-scanning
      # only the Hash shell sees @entries/@indices pointers — not the String keys
      # inside the blob. When the blob is old and soft-dirty missed the page,
      # those nursery keys were swept → Hash UAF (OverflowError / SEGV in
      # HTTP::Headers keep-alive). Precise walk marks nursery targets only
      # (mark_candidate / mark_noscan already no-op on old objects during minor).
      if @layout_precise && size >= 4
        tid = user.as(Int32*).value
        if (entry = Layout.entry_for(tid))
          size_match = entry.alloc_size == 0 || size == entry.alloc_size.to_u64
          if size_match && entry.hash?
            scan_hash_object(user, size, entry)
            return
          end
          if size_match && entry.precise_fields?
            entry.scan_offsets.each do |off|
              next if off.to_u64 + sizeof(Void*).to_u64 > size
              ptr = Pointer(Void*).new(user.address + off.to_u64).value
              mark_candidate(ptr)
              # Old Array(String) @buffer holds nursery element refs.
              scan_buffer_words_for_nursery(ptr)
            end
            # Noscan buffers (Array(UInt8) etc.): usually no refs; still scan
            # cheaply in case a mixed layout parked pointers here.
            entry.noscan_offsets.each do |off|
              next if off.to_u64 + sizeof(Void*).to_u64 > size
              buf = Pointer(Void*).new(user.address + off.to_u64).value
              scan_buffer_words_for_nursery(buf)
            end
            return
          end
        end
      end

      word = sizeof(Void*).to_u64
      words = size // word
      cursor = user.as(UInt64*)
      words.times do |i|
        cand = Pointer(Void).new(cursor[i])
        next unless (h = find_object(cand))
        if BlockHeader.nursery?(h)
          mark_candidate(cand)
        elsif !BlockHeader.atomic?(h)
          # One-level chase: old Hash.@entries / Array.@buffer holding nursery refs.
          scan_buffer_words_for_nursery(cand)
        end
      end
    end

    # Conservative word-scan of a heap buffer for nursery pointers (old→young).
    private def scan_buffer_words_for_nursery(pointer : Void*) : Nil
      header = find_object(pointer)
      return unless header
      return if BlockHeader.free?(header)
      # Keep the buffer itself if it is nursery (rare for long-lived tables).
      mark_candidate(pointer) if BlockHeader.nursery?(header)
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
      # Side mark bitmap: single bitmap zero is O(bitmap_bytes) — proportional
      # to managed heap, not to the live-object count. Replaces the legacy
      # per-object header write that dominated clear_all_marks under HTTP.
      # Use @mark_bitmap directly (not Gcry.current_mark_bitmap) so that under
      # -Dgc_none a test heap does not clobber the process GC's bitmap.
      if bm = @mark_bitmap
        if @heap_max > @heap_min && @heap_min != UInt64::MAX
          bm.reset(@heap_min, @heap_max)
        else
          bm.zero_all
        end
      end
    end

    # Minor GC: reset nursery mark bits only.
    private def clear_nursery_marks : Nil
      # Side mark bitmap: zero only the address ranges that correspond to
      # nursery chunks. Chunks are page-aligned at multiples of the chunk size
      # so we can issue narrow resets without touching the old generation's
      # bits (which carry over from the prior major and remain valid).
      bm = @mark_bitmap
      return unless bm
      each_chunk do |chunk|
        next unless ChunkHeader.nursery?(chunk)
        lo = ChunkHeader.data_start(chunk).address
        hi = chunk.address + chunk.value.mapped_bytes
        bm.reset(lo, hi) if hi > lo
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
      # Use heap-local mark check (not BlockHeader.marked? which reads the
      # global Gcry.current_mark_bitmap) — under -Dgc_none a test heap may
      # have swapped the global bitmap, causing cross-heap false negatives.
      if heap_marked?(header)
        return false
      end
      # False-negative counter: gate rejected the ambient pointer that pointed
      # here, but a different root still walked this object. If the page is
      # also blacklisted (we previously declared similar addresses false), this
      # is exactly the UAF vector the gate is supposed to prevent — record it
      # so a production heap can alert on a non-zero rate.
      if @blacklist_enabled && blacklisted_page?(obj.address) && type_id_plausible?(header)
        @type_id_root_false_negatives += 1
      end
      true
    end
  end
end
