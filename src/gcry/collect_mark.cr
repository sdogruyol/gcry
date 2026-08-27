# Mark phase: candidates, object scan, nursery remembered-set helpers.

module Gcry
  class Heap
    # Ambient-root source tag for per-source reject counters. Distinguishes
    # fiber/mutator stacks, BSS/data segments, and TLS (thread) so the
    # false-positive root cause can be attributed. Cheap enum (1 byte) — passed
    # through mark_root_candidate → mark_impl → mark_impl_unlocked; the case
    # only runs on the type_id gate reject path, so the hot path is unchanged.
    private enum RootSource
      # Running mutator stack (SP→bottom / spill window).
      Stack
      Static
      Thread
      # Heap-to-heap edges — must not FREE-claim (would retain freelists).
      Heap
      # Compiler stack-map precise roots (mark_precise_root). Attribution only.
      Precise
      # Parked fiber stack word-scan (and Crystal GC.push_stack).
      Parked
    end

    # Heap-scan / explicit roots: follow interiors (Array#shift advances @buffer
    # into its allocation). Never apply type_id_gate (raw buffers OK).
    private def mark_candidate(pointer : Void*) : Nil
      mark_impl(pointer, gate_type_id: false, base_only: false, source: RootSource::Heap)
    end

    # Ambient roots (stack / static / fiber stacks): optional type_id gate;
    # base-pointer-only unless GCRY_INTERIOR=1 (cuts false retention).
    #
    # type_id_gate applies to *static* roots only by default. Applying it to
    # stacks rejected live Channel/Deque buffers and similar raw allocations
    # whose first word is not a Crystal type_id — Log::AsyncDispatcher then
    # SEGVd under frequent collect (EC1 + GCRY_THRESHOLD=32KiB boot; also
    # amplified Parallel HTTP pressure). Heap edges still use mark_candidate
    # (no gate). Opt back into stack gating with GCRY_TYPE_ID_GATE=1.
    private def mark_root_candidate(pointer : Void*, source : RootSource = RootSource::Stack) : Nil
      gate = @type_id_gate && (source == RootSource::Static || @type_id_gate_stacks)
      mark_impl(pointer, gate_type_id: gate, base_only: !@allow_interior_pointers, source: source)
    end

    # add_root / collect(roots:) / realloc pin — never type_id_gate (raw Hash
    # @entries / Array @buffer have no Crystal type_id). Interior policy matches
    # ambient roots so allow_interior_pointers still applies.
    private def mark_explicit_root(pointer : Void*) : Nil
      mark_impl(pointer, gate_type_id: false, base_only: !@allow_interior_pointers, source: RootSource::Stack)
    end

    # Compiler stack-map / precise-root entry (docs/STACK_MAPS.md). Same mark
    # policy as add_root; no type_id_gate. Safe to call only during collect.
    # Invoked by StackMaps walker when precise_stack_roots (GCRY_PRECISE_STACK=1).
    def mark_precise_root(pointer : Void*) : Nil
      raise "mark_precise_root outside of collect" unless @collecting
      return if pointer.null?
      @precise_stack_roots_marked += 1
      mark_impl(pointer, gate_type_id: false, base_only: !@allow_interior_pointers, source: RootSource::Precise)
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
      if ThreadListWatch.note_candidate(addr)
        report_thread_list_offer(pointer, gate_type_id)
      end
      return if @heap_max == 0 || addr < @heap_min || addr >= @heap_max
      # Crystal pointers are word-aligned; reject interior/misaligned false hits fast.
      # scan_unaligned_candidates keeps them (GCRY_SOUND) — a misaligned interior
      # into a byte buffer is a root bdwgc would resolve via GC_base.
      return if !@scan_unaligned_candidates && (addr & (sizeof(Void*).to_u64 - 1)) != 0

      header = find_block(pointer)
      return unless header

      # Mid-`tlab_alloc_small` STW: mutator holds FREE freelist nodes on-stack.
      # find_object ignores FREE → empty-chunk munmap risk. Clear FREE but keep
      # next_free so scrub can walk the chain (BlockHeader.set_used would null
      # next_free and sever the freelist → OOM). Do not scan (uninit payload).
      #
      # Also mark the rest of the freelist chain reachable via next_free while
      # leaving those nodes FREE. Stack roots usually hold only the current
      # `user`; TLAB batches the tail. Unmarked FREE tails make all-free chunks
      # look empty → munmap → SEGV in free? when the mutator resumes
      # (Kemal + GCRY_TLAB=1 @ EC1).
      #
      # Minor × old: never claim. Minor does not munmap old chunks, and clearing
      # FREE on an old freelist node (then skipping mark) leaves USED-on-freelist
      # for scrub to drop — silent old-freelist corruption under nursery+TLAB.
      if BlockHeader.free?(header)
        return unless @tlab_enabled && @stop_the_world
        return unless source == RootSource::Stack || source == RootSource::Thread ||
                      source == RootSource::Parked
        if base_only && addr != BlockHeader.user_from(header).address
          return
        end
        if @minor_only && !BlockHeader.nursery?(header)
          return
        end
        h = header.value
        h.flags = h.flags & ~BlockHeader::Flags::FREE
        header.value = h
        heap_set_mark(header) unless heap_marked?(header)
        walk = h.next_free
        while walk
          break unless find_block(walk)
          wh = BlockHeader.from_user(walk)
          break unless BlockHeader.free?(wh)
          heap_set_mark(wh) unless heap_marked?(wh)
          walk = wh.value.next_free
        end
        return
      elsif base_only
        # Object-base only on ambient roots: interiors into String/Array buffers
        # inflate false retention. Heap marks must allow interiors (shift).
        return if addr != BlockHeader.user_from(header).address
      end

      if gate_type_id && !type_id_plausible?(header)
        @type_id_root_rejects += 1
        case source
        when RootSource::Stack, RootSource::Parked
          @type_id_stack_rejects += 1
        when RootSource::Static then @type_id_static_rejects += 1
        when RootSource::Thread then @type_id_thread_rejects += 1
        when RootSource::Heap, RootSource::Precise
          # no dedicated counter
        end
        note_false_root(addr)
        return
      end

      return if heap_marked?(header)
      if @minor_only && !BlockHeader.nursery?(header)
        return
      end

      heap_set_mark(header)
      note_first_mark(header, source) if @live_attr_roots
      @mark_stack.push(header)
    end

    # First-mark source attribution (GCRY_LIVE_ATTR=1). Counts objects/bytes by
    # the root path that *seeded* them; Heap = transitive closure via edges.
    # *_atomic_bytes: malloc_atomic slabs first reached from that source (acik
    # 32 KiB IO buffers). Optional watch type_id → first_mark_watch_*.
    private def note_first_mark(header : BlockHeader*, source : RootSource) : Nil
      bytes = header.value.size.to_u64
      atomic = BlockHeader.atomic?(header)
      case source
      when RootSource::Stack
        @first_mark_stack_objects += 1
        @first_mark_stack_bytes += bytes
        @first_mark_stack_atomic_bytes += bytes if atomic
      when RootSource::Parked
        @first_mark_parked_objects += 1
        @first_mark_parked_bytes += bytes
        @first_mark_parked_atomic_bytes += bytes if atomic
      when RootSource::Static
        @first_mark_static_objects += 1
        @first_mark_static_bytes += bytes
        @first_mark_static_atomic_bytes += bytes if atomic
      when RootSource::Thread
        @first_mark_thread_objects += 1
        @first_mark_thread_bytes += bytes
        @first_mark_thread_atomic_bytes += bytes if atomic
      when RootSource::Precise
        @first_mark_precise_objects += 1
        @first_mark_precise_bytes += bytes
        @first_mark_precise_atomic_bytes += bytes if atomic
      when RootSource::Heap
        @first_mark_heap_objects += 1
        @first_mark_heap_bytes += bytes
        @first_mark_heap_atomic_bytes += bytes if atomic
      end

      watch = @live_attr_watch_tid
      return if watch == 0
      return if bytes < 4
      # Payload starts after BlockHeader (same as heap_dump / live_attr_kind).
      user = Pointer(UInt8).new(header.as(Void*).address + BlockHeader::SIZE)
      tid = user.as(Int32*).value
      return unless tid == watch
      case source
      when RootSource::Stack   then @first_mark_watch_stack += 1
      when RootSource::Parked  then @first_mark_watch_parked += 1
      when RootSource::Static  then @first_mark_watch_static += 1
      when RootSource::Thread  then @first_mark_watch_thread += 1
      when RootSource::Precise then @first_mark_watch_precise += 1
      when RootSource::Heap    then @first_mark_watch_heap += 1
      end
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
      return if !@scan_unaligned_candidates && (addr & (sizeof(Void*).to_u64 - 1)) != 0

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
              # Trust the map only as far as the object's shape supports it.
              # A collision that reaches here degrades to exactly the
              # conservative scan it would have got unregistered.
              plausible = hash_shape_plausible?(user, size, entry)
              scan_hash_object(user, size, entry) if plausible
              scan_hash_body(user, size, entry, demote: plausible)
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
              mark_impl(Pointer(Void).new(cursor[i]), gate_type_id: false, base_only: false, source: RootSource::Heap)
            end
            return
          elsif size_match
            # Leaf / value-only type: nothing to mark in the body.
            # Exception: raw pointer buffers (Array/Deque payloads) have no
            # Crystal header — first UInt64 is a heap pointer (high half ≠ 0).
            # Real References put type_id at 0 and usually padding at 4..7.
            # Colliding with a leaf type_id + alloc_size would skip scanning
            # every element → UAF (Kemal EC4 …0008 class).
            if size >= 8 && (user.as(UInt64*).value >> 32) != 0
              # fall through to full conservative
            else
              @layout_precise_scans += 1
              return
            end
          end
          # size mismatch (or leaf+pointer-shaped header): ignore the layout
          # entry → full conservative.
        end
      end

      @layout_conservative_scans += 1
      # Raw buffers (no Crystal type_id): object-base only — cuts interior false
      # hits from JSON/bytes. Typed References keep interiors so Array#shift and
      # layout-miss types with mid-object pointers stay correct.
      #
      # This is a root-completeness heuristic on *heap edges*, not just on
      # ambient roots: an interior pointer stored inside a Slice / raw buffer is
      # dropped. It is also a second, silent consumer of type_id_plausible? —
      # so with @type_id_gate off, the type_id heuristic still steered marking
      # from here. @allow_interior_pointers (GCRY_INTERIOR / GCRY_SOUND) now
      # switches both off together, which is what makes `root_soundness=sound`
      # a true statement. See docs/SOUND-DEFAULTS.md.
      base_only = !@allow_interior_pointers && size >= 4 && !type_id_plausible?(header)
      word = sizeof(Void*).to_u64
      words = size // word
      cursor = user.as(UInt64*)
      words.times do |i|
        mark_impl(Pointer(Void).new(cursor[i]), gate_type_id: false, base_only: base_only, source: RootSource::Heap)
      end
    end

    # The object's own body, every word of it, with `@entries` / `@indices`
    # demoted to `mark_noscan` so the two blobs stay alive without being walked
    # as pointer arrays — which is the whole reason the Hash kind exists.
    #
    # `scan_hash_object` alone was not enough, and the reason generalises past
    # Hash. A layout is keyed on the payload's **first Int32**, read
    # conservatively; a raw buffer of union values starts with exactly such an
    # id, because Crystal stores the union's type id in the first four bytes.
    # So a 64-byte `Array(JSON::Any)` buffer whose first element is a String is
    # indistinguishable, by that key, from an instance of whichever class holds
    # the same id — and when the size class matches too, nothing downstream
    # notices. Measured on acikturkiye: blocks reading `type_id 208` were
    # scanned to `Hash`'s map, the pointers they really held at +24 and +56
    # were never marked, and the mark audit reported missed edges on 193 of 216
    # collections. The Strings underneath were swept while a request was
    # serialising them (`bench/log/linux/2026-08-24-acikturkiye-live-string-uaf`).
    #
    # Seven words for a 56-byte `Hash`, and it also covers what the map never
    # modelled: `@block`'s closure pointer, and the size-class slack a previous
    # occupant left behind.
    private def scan_hash_body(user : UInt8*, size : UInt64, entry : Layout::Entry,
                               demote : Bool) : Nil
      word = sizeof(Void*).to_u64
      words = size // word
      cursor = user.as(UInt64*)
      i = 0_u64
      while i < words
        value = Pointer(Void).new(cursor[i])
        # Demoting a word to `mark_noscan` is itself a claim about the type —
        # marked, never traced. Make it only where the shape backs the claim;
        # on a colliding block that word may be an ordinary reference whose
        # children still need marking.
        if demote && hash_blob_offset?(entry, i &* word)
          mark_noscan(value)
        else
          mark_impl(value, gate_type_id: false, base_only: false, source: RootSource::Heap)
        end
        i &+= 1
      end
      @layout_hash_bodies &+= 1
    end

    # Does this block actually look like the `Hash` its first Int32 claims?
    #
    # Cheap structural questions only, all of them things a real `Hash` cannot
    # get wrong: a sane `@indices_size_pow2`, non-negative `@size` and
    # `@deleted_count` that fit the capacity that pow2 implies, and `@entries` /
    # `@indices` that are either null or point into the heap. A raw buffer that
    # collided on the type_id passes none of these except by accident.
    private def hash_shape_plausible?(user : UInt8*, size : UInt64, entry : Layout::Entry) : Bool
      word = sizeof(Void*).to_u64
      entries_off = entry.hash_entries_off.to_u64
      indices_off = entry.hash_indices_off.to_u64
      pow2_off = entry.hash_pow2_off.to_u64
      size_off = entry.hash_size_off.to_u64
      deleted_off = entry.hash_deleted_off.to_u64
      return false if entries_off + word > size || indices_off + word > size
      return false if pow2_off + 1 > size
      return false if size_off + 4 > size || deleted_off + 4 > size

      pow2 = Pointer(UInt8).new(user.address + pow2_off).value
      return false if pow2 >= 63

      live = Pointer(Int32).new(user.address + size_off).value
      deleted = Pointer(Int32).new(user.address + deleted_off).value
      return false if live < 0 || deleted < 0

      entries = Pointer(Void*).new(user.address + entries_off).value
      indices = Pointer(Void*).new(user.address + indices_off).value
      return false unless entries.null? || is_heap_ptr(entries)
      return false unless indices.null? || is_heap_ptr(indices)

      # An empty Hash has no tables and no entries; a populated one has both.
      if entries.null?
        return live == 0 && deleted == 0
      end
      capacity = (1_u64 << pow2) // 2
      return false if capacity == 0
      live.to_u64 &+ deleted.to_u64 <= capacity
    end

    private def hash_blob_offset?(entry : Layout::Entry, offset : UInt64) : Bool
      entry.noscan_offsets.each do |off|
        return true if off.to_u64 == offset
      end
      false
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
      # Stale/corrupted @entries (mark miss → reuse) must not SEGV the collector.
      return unless is_heap_ptr(entries)

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
      {% unless flag?(:gcry_side_bitmap) %}
        # Mark generation: bump O(1) so prior marks fail marked? without a heap
        # walk. Was ~3ms phase_clear under Parallel reclaim-off (FREE-dominated).
        # Wrap at 255 → full clear of gen bits (and legacy MARK) then gen=1.
        if @header_mark_gen >= 255_u8
          each_chunk do |chunk|
            each_block_or_large(chunk) do |header|
              next if BlockHeader.free?(header)
              BlockHeader.clear_mark(header)
            end
          end
          @header_mark_gen = 1_u8
          @header_mark_gen_full_clears &+= 1_u64
        else
          @header_mark_gen &+= 1_u8
        end
        BlockHeader.mark_gen = @header_mark_gen
      {% else %}
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
      {% end %}
    end

    # Minor GC: reset nursery mark bits only.
    private def clear_nursery_marks : Nil
      {% unless flag?(:gcry_side_bitmap) %}
        each_chunk do |chunk|
          next unless ChunkHeader.nursery?(chunk)
          each_block(chunk) do |header|
            next if BlockHeader.free?(header)
            BlockHeader.clear_mark(header)
          end
        end
      {% else %}
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
      {% end %}
    end

    private def each_block_or_large(chunk : ChunkHeader*, & : BlockHeader* ->) : Nil
      if ChunkHeader.large?(chunk)
        yield ChunkHeader.data_start(chunk).as(BlockHeader*)
      else
        each_block(chunk) { |h| yield h }
      end
    end

    # After mark, before sweep. Allocation-free (no Crystal Proc/closure).
    # World stopped; registry quiesced at stop_world (no concurrent mutate).
    #
    # Boehm rule: enqueue finalizers for unmarked objects, then *resurrect*
    # them (mark + rematerialize) so sweep does not reclaim before
    # run_pending. Otherwise Socket/Digest#finalize runs on freed memory
    # (acik wrk SEGV). Weak links clear while still unmarked. Next collect
    # reclaims if nothing else holds the object.
    private def enqueue_unreachable_finalizers : Nil
      # Disappearing links first — targets still look dead for WeakRef.
      i = 0
      while i < @finalizers.link_count
        if unmarked_live_object?(@finalizers.link_object_at(i))
          @finalizers.clear_and_remove_link_at(i)
        else
          i += 1
        end
      end

      i = 0
      while i < @finalizers.entry_count
        obj = @finalizers.entry_object_at(i)
        if unmarked_live_object?(obj)
          @finalizers.queue_and_remove_entry_at(i)
          mark_candidate(obj) unless obj.null?
        else
          i += 1
        end
      end

      mark_loop unless @mark_stack.empty?
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
