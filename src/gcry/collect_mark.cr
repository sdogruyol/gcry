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
    #
    # Inlined, with the heap-span test first: the nursery and dirty-page
    # rescans call this once per candidate word, and most words hold no heap
    # address. See the conservative loop in `scan_object`.
    @[AlwaysInline]
    private def mark_candidate(pointer : Void*) : Nil
      addr = pointer.address
      return if addr < @heap_min || addr >= @heap_max
      mark_impl(pointer, gate_type_id: false, base_only: false, source: RootSource::Heap)
    end

    # Ambient roots (stack / static / fiber stacks): optional type_id gate;
    # interiors resolved unless GCRY_DISABLE_INTERIOR=1 (base-only cuts false
    # retention but frees buffers LLVM holds only by an interior pointer).
    #
    # type_id_gate is off by default and, when on, applies to *static* roots
    # only. On stacks it rejected live Channel/Deque buffers and similar raw
    # allocations whose first word is not a Crystal type_id —
    # Log::AsyncDispatcher then SEGVd under frequent collect. On static roots
    # it swept a class variable's `Pointer(String)` buffer the same way, which
    # is why it has been off since 2026-09-29. Heap edges use mark_candidate
    # and were never gated.
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
    # takes the lock.
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
          Gcry::RawOut.print_backtrace
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
      base = slot < 0 ? 0_u64 : pushbuf_base(slot)
      if base == 0_u64
        @mark_lock.lock
        @mark_stack.push(header)
        @mark_lock.unlock
        return
      end
      n = pushbuf_n(slot)
      if n >= MARK_PUSHBUF_CAP
        flush_pushbuf(slot)
        n = 0
      end
      Pointer(Void*).new(base)[n] = header.as(Void*)
      set_pushbuf_n(slot, n + 1)
    end

    private def mark_impl_unlocked(pointer : Void*, gate_type_id : Bool, base_only : Bool, source : RootSource) : Nil
      addr = pointer.address
      if ThreadListWatch.note_candidate(addr)
        report_thread_list_offer(pointer, gate_type_id)
      end
      return if @heap_max == 0 || addr < @heap_min || addr >= @heap_max
      # Crystal pointers are word-aligned, so the filter below is a cheap reject
      # of misaligned false hits - but a misaligned interior into a byte buffer
      # is a root bdwgc would resolve via GC_base, and under --release it can be
      # the only one, so the process GC keeps them (GCRY_ALIGNED_CANDIDATES=1
      # restores the filter for measurement).
      return if !@scan_unaligned_candidates && (addr & (sizeof(Void*).to_u64 - 1)) != 0

      found = find_block_with_chunk(pointer)
      return unless found
      header, chunk = found

      # A candidate that names a block nobody holds is a stale word, not a root.
      #
      # `block_allocated?`, not the header flag: on a bitmap chunk the sweep
      # leaves FREE stale on every block it reclaimed, and marking one would
      # resurrect it into `occ` on the next `occ = mark`.
      #
      # Until 2026-09-28 a TLAB heap "claimed" such a block when a stack or
      # thread root pointed at it: cleared FREE and marked its `next_free`
      # chain, on the theory that a mutator could be stopped holding FREE nodes
      # out of its TLAB and a chunk of them would look empty. That stopped
      # being possible on 2026-09-27. The collector now takes every TLAB slot
      # lock before it stops the world, and a refill overtaken by a stop throws
      # its batch away by epoch (`tlab_refill_once`). The claim was left turning
      # stale FREE pointers into USED blocks on the class lists, and it had
      # already been found corrupting old freelists during a minor
      # (`make nursery-tlab-smoke`; `bench/log/linux/2026-09-28-tlab-claim-retired/`).
      return unless block_allocated?(chunk, header)
      if base_only
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
      # Atomic payloads have no edges. The chunk is already resolved here;
      # preserve its mark and attribution without a queue round trip.
      return if atomic_of(chunk, header)
      mark_stack_push(header)
    end

    # First-mark source attribution (GCRY_LIVE_ATTR=1). Counts objects/bytes by
    # the root path that *seeded* them; Heap = transitive closure via edges.
    # *_atomic_bytes: malloc_atomic slabs first reached from that source (acik
    # 32 KiB IO buffers). Optional watch type_id → first_mark_watch_*.
    private def note_first_mark(chunk : ChunkHeader*, header : BlockHeader*, source : RootSource) : Nil
      # Size and kind come from the chunk: the header alone has neither for a
      # small block on the headerless layout.
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
      # The header's ATOMIC flag first, because it can end the call.
      #
      # It is a load off a line the mark stack pop already pulled in;
      # `chunk_containing` takes `@index_lock` and binary-searches the sorted
      # index. Atomic blocks are the majority of a Crystal heap — every
      # `String` and every pointer-free `Pointer(T).malloc` is one — and they
      # reach here because `mark_impl_unlocked` pushes them before anything
      # knows they are unscanned. Resolving the chunk first cost **+19%** of
      # `phase_mark` on an atomic-heavy live set (400 000 Strings, measured
      # against 287404d), which is why `scan_object_for_nursery` never stopped
      # testing the header first.
      #
      # Sound in both builds: under headerless `BlockHeader.atomic?` is a
      # literal `false`, so it never short-circuits there and the chunk's
      # answer below is still the one that decides.
      return if BlockHeader.atomic?(header)

      # One chunk lookup for the rest of the scan. Under headerless the chunk
      # is the source of *everything* this method used to read from the block —
      # atomicity (7.2), size (7.6) and the type_id gate's length — so resolving
      # it once and reusing it beats three separate derivations.
      chunk = chunk_containing(header.address)
      return unless chunk
      return if atomic_of(chunk, header)

      user = user_of(chunk, header).as(UInt8*)
      size = block_payload(chunk, header).to_u64
      return if size == 0
      # Serial mark only. Four helpers adding to one field per object is the
      # shared-line write that already costs parallel mark its scaling; a
      # parallel cycle leaves the count short, and the cap stays at its floor.
      @mark_scanned_bytes &+= size unless @mark_parallel

      # No type map narrows this scan. The removed `Gcry::Layout` keyed one off the
      # payload's first Int32, and a raw buffer of a mixed union starts with
      # exactly such an id: Crystal tags every element with its runtime type
      # id. `[JSON::Any.new(array), JSON::Any.new("x")]` is a 32-byte buffer
      # that read as an `Array(JSON::Any)`, `[hash, nil, 1_i64, nil]` a 64-byte
      # one that passed the `Hash` shape check, and both had live elements
      # swept (`bench/log/linux/2026-10-04-layout-union-collision/`), as
      # acikturkiye's had in August behind the guards of the day
      # (`bench/log/linux/2026-08-24-acikturkiye-live-string-uaf`). The maps
      # bought nothing this scan does not: a non-atomic block is zeroed to its
      # whole size class, Crystal allocates pointer-free classes and buffers
      # atomic, and `Hash` clears the entries it deletes or compacts away.
      #
      # Raw buffers (no Crystal type_id): object-base only — cuts interior false
      # hits from JSON/bytes. Typed References keep interiors so Array#shift and
      # types with mid-object pointers stay correct.
      #
      # This is a root-completeness heuristic on *heap edges*, not just on
      # ambient roots: an interior pointer stored inside a Slice / raw buffer is
      # dropped. It is also a second, silent consumer of type_id_plausible? —
      # so with @type_id_gate off, the type_id heuristic still steered marking
      # from here. @allow_interior_pointers (on by default; GCRY_DISABLE_INTERIOR) now
      # switches both off together, which is what makes `root_soundness=sound`
      # a true statement. See docs/SOUND-DEFAULTS.md.
      base_only = !@allow_interior_pointers && size >= 4 && !type_id_plausible?(chunk, header)
      word = sizeof(Void*).to_u64
      words = size // word
      # The planted miss of `make mark-audit` (`mark_test_short_tid`).
      if (short = @mark_test_short_tid) != 0 && words > 0 && user.as(Int32*).value == short
        words -= 1
      end
      cursor = user.as(UInt64*)
      # Most words of a scanned body are not heap addresses: nulls, small
      # integers, hashes, floats. `mark_impl_unlocked` rejects them on its
      # first range test, but only after a call it does not get inlined into,
      # about 20 instructions a word. The same test here, against the bounds
      # loaded once (no chunk is mapped or unmapped during a mark), keeps the
      # call for words that can be heap pointers.
      lo = @heap_min
      hi = @heap_max
      words.times do |i|
        w = cursor[i]
        next if w < lo || w >= hi
        mark_impl(Pointer(Void).new(w), gate_type_id: false, base_only: base_only, source: RootSource::Heap)
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
      return unless @nursery_old_scan
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
      page = Gcry::OS.mmap(
        Pointer(Void).null,
        LibC::SizeT.new(Platform::PAGE_SIZE),
        Gcry::OS::PROT_READ | Gcry::OS::PROT_WRITE,
        Gcry::OS::MAP_PRIVATE | Gcry::OS::MAP_ANONYMOUS,
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
        Gcry::OS.munmap(page, LibC::SizeT.new(Platform::PAGE_SIZE))
      end
    end

    private def scan_object_for_nursery(header : BlockHeader*) : Nil
      return if BlockHeader.atomic?(header)
      chunk = chunk_containing(header.address)
      return unless chunk
      user = user_of(chunk, header).as(UInt8*)
      size = block_payload(chunk, header).to_u64
      return if size == 0

      # Old Hash objects store keys/values in a separate @entries blob. When the
      # blob is old and soft-dirty missed its page, the nursery keys inside were
      # swept → Hash UAF (OverflowError / SEGV in HTTP::Headers keep-alive). The
      # one-level chase below reads it from the Hash shell.

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
        clear_walk do |chunk|
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

      # Walked through the **index**, not the `@chunks` list, and both of these
      # clears are. The marker resolves a candidate's chunk with
      # `chunk_containing`, which reads the index — so a chunk in the index can
      # have its blocks marked whether or not it is on the list, and a clear
      # that walks the list can leave those marks standing. What that costs is
      # written two comments below, for the nursery case that hit it: the block
      # reads marked forever, `mark_impl` returns early without scanning it,
      # and anything reachable only through it is reclaimed while live.
      #
      # The index is the superset. Measured over every run of `make
      # thread-churn-uaf`: chunks on the list and not indexed, **0**; indexed
      # and not listed, 1 in about 14 runs
      # (`GCRY_CHUNK_LIST_AUDIT=1`). So this can only cover more, at the same
      # element count.
      #
      # Latent rather than observed, and said plainly: with the list walk,
      # `GCRY_MARK_CLEAR_AUDIT=1` finds residue in **0 of 20 runs** — the
      # chunks that leave the list have already been swept, which clears their
      # marks, and nothing marked into them again before the run ended. This
      # closes the hazard and the audit is what keeps it closed.
      # `bench/log/linux/2026-09-12-writer-frames/FINDINGS.md`
      #
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
        clear_walk do |chunk|
          next if ChunkHeader.large?(chunk)
          chunk_clear_marks(chunk)
        end
      end
      audit_mark_clear if @mark_clear_audit
      {% if flag?(:gcry_hl_assert) %} hl_pushed_reset; hl_stack_seed_reset {% end %}
    end

    # Did the clear reach every chunk the marker can reach?
    #
    # `mark_impl` resolves a candidate's chunk through `chunk_containing`, which
    # reads the index — so a chunk in the index can have its blocks marked
    # whether or not it is on `@chunks`. A chunk whose marks were not cleared
    # has blocks that read marked forever, and this file already records what
    # that costs: "the block then read marked forever, `mark_impl` returned
    # early without scanning it, and anything reachable only through it was
    # reclaimed **while live**."
    #
    # `GCRY_MARK_CLEAR_AUDIT=1`. O(bitmap bytes) again, so research only.
    # The set the clear covers. `GCRY_MARK_CLEAR_LIST=1` puts it back on the
    # `@chunks` list, which is what every build did until 2026-09-13 and which
    # misses a chunk the index knows about and the list does not.
    private def clear_walk(& : ChunkHeader* ->) : Nil
      if @mark_clear_list
        each_chunk { |chunk| yield chunk }
      else
        each_indexed_chunk { |chunk| yield chunk }
      end
    end

    private def audit_mark_clear : Nil
      residue = 0_u64
      first = 0_u64
      each_indexed_chunk do |chunk|
        next if ChunkHeader.large?(chunk)
        next unless bitmap_chunk?(chunk)
        mark = ChunkHeader.mark_bitmap(chunk)
        next if mark.null?
        words = chunk.value.bitmap_words.to_i32
        i = 0
        dirty = false
        while i < words
          if mark[i] != 0
            dirty = true
            break
          end
          i += 1
        end
        next unless dirty
        residue &+= 1
        first = chunk.address if first == 0
      end
      @mark_clear_residue &+= residue
      return if residue == 0
      return unless @mark_clear_residue == residue
      buf = uninitialized UInt8[RawOut::LIMIT]
      len = RawOut.append(buf.to_unsafe, 0, "gcry: the mark clear missed ")
      len = RawOut.append_u64(buf.to_unsafe, len, residue)
      len = RawOut.append(buf.to_unsafe, len, " indexed chunk(s) (first 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, first)
      len = RawOut.append(buf.to_unsafe, len,
        ") — their blocks read marked forever, so `mark_impl` returns early on them and nothing " \
        "follows their edges. collection ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # Minor GC: reset nursery mark bits only.
    #
    # Old-generation marks are retained on purpose — a minor bumps no
    # generation, and `mark_impl`'s `@minor_only` gate skips non-nursery blocks,
    # so the old generation's marks stay valid from the prior major. The bitmap
    # arm has to preserve exactly that asymmetry.
    #
    # And it has to clear the representation the *read* side will consult.
    # That is `bitmap_chunk?`, which excludes nursery chunks — they keep the
    # header representation, because the nursery is still header-based
    # (`sweep_small_blocks` dispatches per chunk for the same reason). Gating
    # this on the global `@bitmap_marks` instead zeroed a nursery chunk's
    # bitmap, which nothing ever writes, and left the header mark set: the
    # block then read marked forever, `mark_impl` returned early without
    # scanning it, and anything reachable only through it was reclaimed **while
    # live**. Reproduced with `GCRY_BITMAP=1` and a nursery: parent rooted,
    # major, child allocated and stored into the parent, one minor — the child
    # was freed and its address handed out again.
    # `GCRY_NURSERY_MARKS_GLOBAL=1` restores that global gate;
    # `make nursery-bitmap-marks --disabled` requires the child to vanish.
    private def clear_nursery_marks : Nil
      each_chunk do |chunk|
        next unless ChunkHeader.nursery?(chunk)
        use_bitmap = @nursery_marks_global ? @bitmap_marks : bitmap_chunk?(chunk)
        if use_bitmap
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
          # Research only (`finalizer_resurrect = false`,
          # `GCRY_FINALIZER_NO_RESURRECT=1`): skip the resurrection, so the
          # sweep reclaims the block and the callback runs on freed memory —
          # the pre-Boehm-rule behaviour. `make finalizer-complex --broken`
          # requires the callback to find its object gone.
          mark_candidate(obj) if @finalizer_resurrect && !obj.null?
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
