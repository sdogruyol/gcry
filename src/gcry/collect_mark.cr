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
      {% if flag?(:gcry_hl_assert) %}
        # Stack-seed dump: which stack words become first marks, and what they
        # point at. Printed only when the candidate is accepted and was not
        # already marked — i.e. the stack alone is what keeps it alive.
        if source == RootSource::Stack && (found = find_block_with_chunk(pointer))
          h, c = found
          if block_allocated?(c, h) && !block_marked_in?(c, h) && @hl_stack_seed_dump < 60
            @hl_stack_seed_dump += 1
            u = user_of(c, h)
            w0 = u.as(UInt64*).value
            w1 = (u.as(UInt64*) + 1).value
            slot = Roots.hl_slot
            LibC.printf("STACKSEED cand=%p user=%p base=%d size=%u w0=%llx w1=%llx slot=%p off_entry=%lld off_bottom=%lld\n",
              pointer, u, pointer.address == u.address ? 1 : 0, block_payload(c, h), w0, w1,
              Pointer(Void).new(slot), slot.to_i64 - @collect_entry_sp.to_i64, @stack_bottom.address.to_i64 - slot.to_i64)
          end
        end
      {% end %}
      mark_impl(pointer, gate_type_id: gate, base_only: !@allow_interior_pointers, source: source)
    end

    {% if flag?(:gcry_hl_assert) %}
      @hl_stack_seed_dump = 0

      def hl_stack_seed_reset : Nil
        @hl_stack_seed_dump = 0
      end
    {% end %}

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

    # No lock here.
    #
    # The per-word acceptance — `find_block_with_chunk`, the alignment and
    # type_id gates, `block_marked_in?` — is read-only and safe under STW (the
    # chunk index does not mutate while the world is stopped). Wrapping all of
    # it in one global spinlock, as this used to, serialised every worker's
    # marking and made `GCRY_PARALLEL_MARK=8` run 60x slower than serial. The
    # only shared mutations are the mark bit (atomic on the bitmap path, and
    # per-object with no shared word on the header path, so double-marking is
    # idempotent) and the mark-stack push, which is the one thing that still
    # takes the lock, plus the TLAB free-claim's freelist surgery.
    @[AlwaysInline]
    private def mark_impl(pointer : Void*, gate_type_id : Bool, base_only : Bool, source : RootSource) : Nil
      mark_impl_unlocked(pointer, gate_type_id, base_only, source)
    end

    # Push a header onto the shared mark stack. Locked only under parallel mark;
    # the stack itself is not thread-safe.
    # Push a discovered child. Serial: straight to the shared stack. Parallel:
    # into this worker's shard buffer, unlocked (single-writer per slot),
    # flushed to the shared stack in batches by `flush_pushbuf`. That batching
    # is what takes the lock off the per-object path.
    @[AlwaysInline]

    {% if flag?(:gcry_hl_assert) %}
      # Double-push catcher: one bit per 16 bytes of the heap span, set on push,
      # reset at the start of every cycle. A repeat push prints where it came
      # from and what the mark bit reads at that instant, then exits.
      @hl_pushed_base : UInt64* = Pointer(UInt64).null
      @hl_pushed_words = 0_u64
      @hl_pushed_lo = 0_u64

      def hl_pushed_reset : Nil
        lo = @heap_min
        hi = @heap_max
        span = hi > lo ? hi - lo : 0_u64
        words = (span >> 4 >> 6) + 1
        if @hl_pushed_base.null? || words > @hl_pushed_words || lo != @hl_pushed_lo
          @hl_pushed_base = LibC.malloc(LibC::SizeT.new(words * 8)).as(UInt64*)
          @hl_pushed_words = words
          @hl_pushed_lo = lo
        end
        @hl_pushed_base.clear(@hl_pushed_words.to_i) unless @hl_pushed_base.null?
      end

      private def hl_note_push(header : BlockHeader*) : Nil
        return if @hl_pushed_base.null?
        return if header.address < @hl_pushed_lo
        idx = (header.address - @hl_pushed_lo) >> 4
        w = idx >> 6
        return if w >= @hl_pushed_words
        bit = 1_u64 << (idx & 63)
        if (@hl_pushed_base[w] & bit) != 0
          c = chunk_containing(header.address)
          ord = c ? chunk_block_ordinal(c, header.address) : 0_u64
          cls = c ? c.value.size_class : 0_u32
          mk = c ? chunk_marked?(c, ord) : false
          LibC.printf("HL DOUBLE PUSH header=%p class=%u ordinal=%llu marked_now=%d chunk=%p\n",
            header.as(Void*), cls, ord, mk ? 1 : 0, c ? c.as(Void*) : Pointer(Void).null)
          Exception::CallStack.print_backtrace
          LibC.exit(9)
        end
        @hl_pushed_base[w] |= bit
      end
    {% end %}

    private def mark_stack_push(header : BlockHeader*) : Nil
      {% if flag?(:gcry_hl_assert) %} hl_note_push(header) {% end %}
      unless @mark_parallel
        @mark_stack.push(header)
        return
      end
      slot = Heap.mark_worker
      # A thread with no claimed slot (should not happen on a mark worker) falls
      # back to the locked shared push rather than corrupting slot -1.
      if slot < 0 || @mark_pushbuf[slot] == 0_u64
        @mark_lock.lock
        @mark_stack.push(header)
        @mark_lock.unlock
        return
      end
      n = @mark_pushbuf_n[slot]
      if n >= MARK_PUSHBUF_CAP
        flush_pushbuf(slot)
        n = 0
      end
      Pointer(Void*).new(@mark_pushbuf[slot])[n] = header.as(Void*)
      @mark_pushbuf_n[slot] = n + 1
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

      found = find_block_with_chunk(pointer)
      return unless found
      header, chunk = found

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
      # `block_allocated?`, not the header flag: on a bitmap chunk the sweep
      # leaves FREE stale on every block it reclaimed, and marking one would
      # resurrect it into `occ` on the next `occ = mark`.
      if !block_allocated?(chunk, header)
        return unless @tlab_enabled && @stop_the_world
        return unless source == RootSource::Stack || source == RootSource::Thread ||
                      source == RootSource::Parked
        if base_only && addr != user_of(chunk, header).address
          return
        end
        if @minor_only && !BlockHeader.nursery?(header)
          return
        end
        # Freelist surgery (clear FREE, walk next_free) mutates shared list
        # state, so it stays under the lock when parallel.
        claim_free_tlab_block(header, chunk)
        return
      elsif base_only
        # Object-base only on ambient roots: interiors into String/Array buffers
        # inflate false retention. Heap marks must allow interiors (shift).
        return if addr != user_of(chunk, header).address
      end

      if gate_type_id && !type_id_plausible?(chunk, header)
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

      return if block_marked_in?(chunk, header)
      if @minor_only && !BlockHeader.nursery?(header)
        return
      end

      set_block_mark_in(chunk, header)
      note_first_mark(chunk, header, source) if @live_attr_roots
      mark_stack_push(header)
    end

    # The TLAB on-stack-freelist claim, isolated so it can hold the lock without
    # putting one on the common mark path. See the long note at the call site.
    private def claim_free_tlab_block(header : BlockHeader*, chunk : ChunkHeader*) : Nil
      locked = @mark_parallel
      @mark_lock.lock if locked
      begin
        h = header.value
        h.flags = h.flags & ~BlockHeader::Flags::FREE
        header.value = h
        # bitmap_alloc replaces the freelist with the pool cursor — no on-stack
        # freelist nodes to claim, so this cannot fire there.
        return if @bitmap_alloc
        set_block_mark_in(chunk, header) unless block_marked_in?(chunk, header)
        walk = h.next_free
        while walk
          walk_found = find_block_with_chunk(walk)
          break unless walk_found
          _, walk_chunk = walk_found
          wh = BlockHeader.from_user(walk)
          break unless BlockHeader.free?(wh)
          set_block_mark_in(walk_chunk, wh) unless block_marked_in?(walk_chunk, wh)
          walk = wh.value.next_free
        end
      ensure
        @mark_lock.unlock if locked
      end
    end

    # First-mark source attribution (GCRY_LIVE_ATTR=1). Counts objects/bytes by
    # the root path that *seeded* them; Heap = transitive closure via edges.
    # *_atomic_bytes: malloc_atomic slabs first reached from that source (acik
    # 32 KiB IO buffers). Optional watch type_id → first_mark_watch_*.
    private def note_first_mark(chunk : ChunkHeader*, header : BlockHeader*, source : RootSource) : Nil
      # Size and kind come from the chunk: the header alone has neither for a
      # small block under `-Dgcry_headerless`.
      bytes = block_payload(chunk, header).to_u64
      atomic = atomic_of(chunk, header)
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
    # Diagnostic callers with no chunk in hand. Resolves it, then delegates.
    private def type_id_plausible?(header : BlockHeader*) : Bool
      chunk = chunk_containing(header.address)
      return false unless chunk
      type_id_plausible?(chunk, header)
    end

    private def type_id_plausible?(chunk : ChunkHeader*, header : BlockHeader*) : Bool
      return true if atomic_of(chunk, header)
      # Size from the chunk (7.6). Reading it from the block under headerless
      # returns the object's own first word — its type_id — so the gate compared
      # the type_id against itself and rejected live objects, which were then
      # swept and their memory handed out twice.
      size = block_payload(chunk, header).to_u64
      return true if size < 4

      tid = user_of(chunk, header).as(Int32*).value
      # Crystal type ids are dense positive integers (0 is not a real instance id;
      # a leading zero word is typical of Pointer(T) buffers / empty slots).
      return false if tid <= 0
      return false if tid > 1_000_000
      true
    end

    private def mark_loop : Nil
      until @mark_stack.empty?
        scan_object(@mark_stack.pop)
      end
    end

    # Depth of the mark-loop prefetch ring. simdgc measured 16-32 as the knee
    # (mark 23 -> 13 ms); past ~64 the line-fill buffers oversubscribe.
    MARK_PREFETCH_DEPTH = 16

    # Serial mark drain with a fixed-depth software prefetch pipeline.
    #
    # A plain LIFO drain pops an object and scans it immediately, so its cache
    # line — random on a real graph, and mark is latency-bound not
    # compute-bound (`simdgc-perf-notes.md`: 147 ns per dependent miss) — is
    # loaded on the critical path every time.
    #
    # The ring decouples pop from scan by `MARK_PREFETCH_DEPTH`: an object is
    # prefetched when it enters, scanned when it leaves, and the K objects
    # between hide the miss. The stack underneath stays strict LIFO, so depth is
    # still bounded by graph depth — no BFS blow-up, no `MarkStack#grow` raising
    # `OutOfMemoryError` (which allocates, the -Dgc_none deadlock). The ring is a
    # fixed reorder buffer in front of scan, not a second work list.
    #
    # `GCRY_PREFETCH=0` selects the plain drain for A/B.
    @[AlwaysInline]
    private def serial_mark_drain : Nil
      unless @mark_prefetch
        until @mark_stack.empty?
          scan_object(@mark_stack.pop)
        end
        return
      end

      ring = uninitialized StaticArray(BlockHeader*, MARK_PREFETCH_DEPTH)
      head = 0
      count = 0
      stack = @mark_stack
      loop do
        while count < MARK_PREFETCH_DEPTH && !stack.empty?
          h = stack.pop
          # Header line and the payload's first line — the type_id gate and the
          # first scanned word both live there.
          Kernels.prefetch_read(h.as(Void*))
          Kernels.prefetch_read((h.as(UInt8*) + BlockHeader::SIZE).as(Void*))
          ring[(head + count) % MARK_PREFETCH_DEPTH] = h
          count += 1
        end
        break if count == 0
        h = ring[head]
        head = (head + 1) % MARK_PREFETCH_DEPTH
        count -= 1
        scan_object(h)
      end
    end

    private def mark_loop_budget(work_units : Int32) : Nil
      units = 0
      while units < work_units && !@mark_stack.empty?
        scan_object(@mark_stack.pop)
        units += 1
      end
    end

    private def scan_object(header : BlockHeader*) : Nil
      # One chunk lookup for the whole scan. Under headerless the chunk is the
      # source of *everything* this method used to read from the block —
      # atomicity (7.2), size (7.6) and the type_id gate's length — so resolving
      # it once and reusing it beats three separate derivations.
      chunk = chunk_containing(header.address)
      return unless chunk
      return if atomic_of(chunk, header)

      user = user_of(chunk, header).as(UInt8*)
      size = block_payload(chunk, header).to_u64
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
      base_only = !@allow_interior_pointers && size >= 4 && !type_id_plausible?(chunk, header)
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

    # Scan length for one object, derived from its **chunk** (Phase 7.6).
    #
    # This used to read `header.value.size` and clamp it against the chunk, then
    # (778b956) skip the lookup entirely for small blocks by trusting the header.
    # Both forms needed the header. The chunk now arrives on the mark stack
    # beside the object, so the size comes from the size class directly — no
    # header read and no lookup, which is what lets the header go while keeping
    # the -7.7% that removing the per-object `chunk_containing` bought.
    #

    private def scan_old_for_nursery_pointers : Nil
      # Soft-dirty/mprotect can *help* mark from dirty pages, but must not
      # replace the full old→young walk: WSL soft-dirty false-negatives under
      # release HTTP left nursery Hash keys unmarked → SEGV.
      scan_dirty_pages_for_pointers(nursery_only: true)

      each_chunk do |chunk|
        if ChunkHeader.large?(chunk)
          header = ChunkHeader.large_header(chunk)
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
      chunk = chunk_containing(header.address)
      return unless chunk
      user = user_of(chunk, header).as(UInt8*)
      size = block_payload(chunk, header).to_u64
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

      chunk = chunk_containing(header.address)
      return unless chunk
      user = user_of(chunk, header).as(UInt8*)
      size = block_payload(chunk, header).to_u64
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
      # Header generation: bump O(1) so prior marks fail `marked?` without a
      # heap walk. Was ~3ms phase_clear under Parallel reclaim-off
      # (FREE-dominated). Wrap at 255 -> full clear of gen bits (and legacy
      # MARK) then gen=1. Large chunks use this under both representations, so
      # it runs either way.
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

      # Size-class chunks on the bitmap path have no generation to bump, so
      # their marks are zeroed wholesale, one chunk at a time. Never per bit:
      # 64 blocks share a word, so clearing one block's bit is a
      # read-modify-write over 63 other blocks' marks.
      #
      # This runs at the *start* of a cycle, before mark, so the marks the
      # previous cycle's sweep read are still intact when it reads them.
      #
      # O(bitmap bytes) rather than O(1) — 1/512th of the heap, so ~2 MiB of
      # memset per GiB, against a mark phase measured in milliseconds. It could
      # be made a no-op in the common case (the sweep visits every non-dormant
      # chunk anyway, so it could clear as it goes, leaving this needed only
      # after a minor), but that is an optimisation with a correctness edge —
      # dormant chunks the sweep skips, chunks mapped mid-cycle — and it is not
      # worth taking before the cost shows up in a measurement.
      if @bitmap_marks
        each_chunk do |chunk|
          next if ChunkHeader.large?(chunk)
          chunk_clear_marks(chunk)
        end
      end
      {% if flag?(:gcry_hl_assert) %} hl_pushed_reset; hl_stack_seed_reset {% end %}
    end

    # Minor GC: reset nursery mark bits only.
    #
    # Old-generation marks are retained on purpose — a minor bumps no
    # generation, and `mark_impl`'s `@minor_only` gate skips non-nursery blocks,
    # so the old generation's marks stay valid from the prior major. The bitmap
    # arm has to preserve exactly that asymmetry.
    private def clear_nursery_marks : Nil
      each_chunk do |chunk|
        next unless ChunkHeader.nursery?(chunk)
        if @bitmap_marks && !ChunkHeader.large?(chunk)
          chunk_clear_marks(chunk)
        else
          each_block(chunk) do |header|
            next if BlockHeader.free?(header)
            BlockHeader.clear_mark(header)
          end
        end
      end
    end

    private def each_block_or_large(chunk : ChunkHeader*, & : BlockHeader* ->) : Nil
      if ChunkHeader.large?(chunk)
        yield ChunkHeader.large_header(chunk)
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
      # Use the heap-local mark check, not the static `BlockHeader.marked?`:
      # under `GCRY_BITMAP=1` the header generation is not where the marks are,
      # and the static reader would answer for the wrong representation.
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
