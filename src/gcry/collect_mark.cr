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
    # Inlined, with the heap-span test first: the precise scans (layout
    # offsets, Hash entries) call this once per slot, and most slots hold no
    # heap address. See the conservative loop in `scan_object`.
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
            LibC.printf("STACKSEED cand=%p user=%p base=%d size=%llu w0=%llx w1=%llx slot=%p off_entry=%lld off_bottom=%lld\n",
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

      private def hl_note_push(entry : BlockHeader*) : Nil
        return if @hl_pushed_base.null?
        header = mark_entry_header(entry)
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

    # `shard` is the pushing thread's parallel-mark shard when the caller has
    # it; nil otherwise, and under parallel mark it is then looked up out of
    # line (`push_to_own_shard`, see `Heap#mark_shard`).
    private def mark_stack_push(header : BlockHeader*, shard : MarkShard? = nil) : Nil
      {% if flag?(:gcry_hl_assert) %} hl_note_push(header) {% end %}
      unless @mark_parallel
        @mark_stack.push(header)
        return
      end
      if shard
        push_to_shard(header, shard)
      else
        push_to_own_shard(header)
      end
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
      mark_stack_push(mark_entry(chunk, header))
    end

    # A mark-stack entry is a block header pointer, and the trace's own pushes
    # carry the block's size class in its top byte (class + 1; 0 = untagged).
    # `scan_object` then has everything it needs — the payload starts at the
    # header and its length is the class's — without resolving the chunk a
    # second time: a radix walk, the chunk header's line and its checks, per
    # scanned object, for a chunk `mark_impl_unlocked` had in hand at the push.
    #
    # The width is what matters on this stack: carrying the chunk as a second
    # word was +13.4% mark (see `MarkStack#push`). The byte costs nothing —
    # user-space addresses stop at bit 47 (bit 56 under five-level paging) on
    # the x86_64 and aarch64 targets gcry is limited to (platform/os.cr).
    # Large blocks and every other push site (the barrier's re-scan; the
    # parallel flush copies entries verbatim) stay untagged and take the
    # resolving path.
    #
    # One tag is not a class: `MARK_ENTRY_TAG_REST` names the unscanned rest
    # of a large payload by the address it resumes at (`scan_large_from`).
    MARK_ENTRY_TAG_SHIFT =                        56
    MARK_ENTRY_ADDR_MASK = 0x00FF_FFFF_FFFF_FFFF_u64
    MARK_ENTRY_TAG_REST  =                  0xFF_u64

    # Under parallel mark a large payload is scanned this many bytes at a
    # time, the rest pushed where any worker can take it, as Boehm splits a
    # long range for its markers. Whole, one worker walked JsonGenerate's
    # 70+ MB `Array(Coordinate)` buffer — every element's candidates resolved
    # in series — while the others spun on an empty stack: with four workers
    # its Σ mark was 471 ms whole and 359 ms split.
    MARK_SPLIT_BYTES = 65536_u64

    @[AlwaysInline]
    private def mark_entry(chunk : ChunkHeader*, header : BlockHeader*) : BlockHeader*
      return header if ChunkHeader.large?(chunk)
      tag = chunk.value.size_class.to_u64 &+ 1
      Pointer(BlockHeader).new(header.address | (tag << MARK_ENTRY_TAG_SHIFT))
    end

    # The header an entry names, tag stripped.
    @[AlwaysInline]
    private def mark_entry_header(entry : BlockHeader*) : BlockHeader*
      Pointer(BlockHeader).new(entry.address & MARK_ENTRY_ADDR_MASK)
    end

    # First-mark source attribution (GCRY_LIVE_ATTR=1). Counts objects/bytes by
    # the root path that *seeded* them; Heap = transitive closure via edges.
    # *_atomic_bytes: malloc_atomic slabs first reached from that source (acik
    # 32 KiB IO buffers). Optional watch type_id → first_mark_watch_*.
    private def note_first_mark(chunk : ChunkHeader*, header : BlockHeader*, source : RootSource) : Nil
      # Size and kind come from the chunk: the header alone has neither for a
      # small block on the headerless layout.
      bytes = block_payload(chunk, header)
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
      size = block_payload(chunk, header)
      return true if size < 4

      type_id_word_plausible?(user_of(chunk, header).as(UInt8*))
    end

    # The payload's first Int32 read as a type id, for a non-atomic payload of
    # at least four bytes.
    @[AlwaysInline]
    private def type_id_word_plausible?(user : UInt8*) : Bool
      tid = user.as(Int32*).value
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
          prefetch_mark_entry(h)
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

    # Bytes of a small payload `prefetch_mark_entry` asks for, at most.
    MARK_PREFETCH_MAX_BYTES = 256_u64

    # Prefetch what `scan_object` will read of one entry: every line of a
    # tagged (small) block up to `MARK_PREFETCH_MAX_BYTES`, as its class gives
    # the length; the first line, and the payload's, of anything else.
    #
    # It used to be the first line only. Once the candidates were resolved in
    # place (`scan_edges_inline`), the scan's own word loads were the largest
    # stall left in the serial mark — 38% of `scan_edges_inline`'s samples on
    # Primes waited on a payload word — since a small object starts anywhere
    # in a line, and the scanned ones average 53 bytes on Primes and 100 on
    # JsonParsePure. Whole payloads, serial Σ mark over 7 interleaved runs:
    # Primes 592 → 493 ms, JsonParsePure 498 → 392 ms; Binarytrees,
    # JsonGenerate and JsonParseSerializable +1 to +7%, at the edge of their
    # run-to-run spread, wall time unchanged. Against 403 ms at this cap,
    # JsonParsePure took 488 ms capped at 64 bytes and 457 ms at 128; 512
    # bytes and 1 KiB were no faster. Fixed prefetches in place of the loop —
    # first and last line (514 ms), or three lines (436 ms) — lost most or
    # part of it (`bench/log/linux/2026-10-06-mark-cost/`). Lines are taken as
    # 64 bytes: on a 128-byte-line core every second prefetch names a line
    # already requested.
    @[AlwaysInline]
    private def prefetch_mark_entry(entry : BlockHeader*) : Nil
      a = mark_entry_header(entry).address
      Kernels.prefetch_read(Pointer(Void).new(a))
      tag = entry.address >> MARK_ENTRY_TAG_SHIFT
      if tag == 0 || tag == MARK_ENTRY_TAG_REST
        Kernels.prefetch_read(Pointer(Void).new(a &+ BlockHeader::SIZE))
        return
      end
      bytes = @block_bytes.unsafe_fetch(tag.to_i32 &- 1)
      bytes = MARK_PREFETCH_MAX_BYTES if bytes > MARK_PREFETCH_MAX_BYTES
      line = (a | 63_u64) &+ 1
      finish = a &+ bytes
      while line < finish
        Kernels.prefetch_read(Pointer(Void).new(line))
        line &+= 64
      end
    end

    private def mark_loop_budget(work_units : Int32) : Nil
      units = 0
      while units < work_units && !@mark_stack.empty?
        scan_object(@mark_stack.pop)
        units += 1
      end
    end

    private def scan_object(entry : BlockHeader*, shard : MarkShard? = nil) : Nil
      # A tagged entry is a small, non-atomic block of a known class (see
      # `mark_entry`): its payload and length need no chunk. The rest tag is
      # the unscanned tail of a large payload.
      tag = entry.address >> MARK_ENTRY_TAG_SHIFT
      if tag != 0
        if tag == MARK_ENTRY_TAG_REST
          from = mark_entry_header(entry).address
          chunk = chunk_containing(from)
          return unless chunk && ChunkHeader.large?(chunk)
          scan_large_from(chunk, ChunkHeader.large_header(chunk), from, shard)
          return
        end
        user = BlockHeader.user_from(mark_entry_header(entry)).as(UInt8*)
        size = @block_bytes[tag.to_i32 &- 1] &- BlockHeader::SIZE
        # `type_id_plausible?` for such a block, which is never atomic and
        # never shorter than four bytes.
        base_only = !@allow_interior_pointers && !type_id_word_plausible?(user)
        scan_payload(user, size, base_only, 0_u64, 0_u64, shard)
        return
      end
      header = entry

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
      if ChunkHeader.large?(chunk)
        scan_large_from(chunk, header, user_of(chunk, header).address, shard)
        return
      end
      scan_block(chunk, header, 0_u64, 0_u64, shard)
    end

    # A large payload from byte address `from` on. Under parallel mark at most
    # `MARK_SPLIT_BYTES` of it, after the rest has gone onto the shared stack
    # as one `MARK_ENTRY_TAG_REST` entry, so an idle worker takes it while
    # this one scans. The planted miss of `make mark-audit` drops a payload's
    # last word, so a payload it applies to is not split.
    private def scan_large_from(chunk : ChunkHeader*, header : BlockHeader*, from : UInt64,
                                shard : MarkShard? = nil) : Nil
      return if atomic_of(chunk, header)
      user = user_of(chunk, header).as(UInt8*)
      size = block_payload(chunk, header)
      finish = user.address &+ size
      return if from >= finish
      base_only = !@allow_interior_pointers && size >= 4 && !type_id_plausible?(chunk, header)
      if @mark_parallel && @mark_test_short_tid == 0 && finish &- from > MARK_SPLIT_BYTES
        rest = from &+ MARK_SPLIT_BYTES
        publish_mark_entry(Pointer(BlockHeader).new(rest | (MARK_ENTRY_TAG_REST << MARK_ENTRY_TAG_SHIFT)))
        scan_payload(Pointer(UInt8).new(from), MARK_SPLIT_BYTES, base_only, 0_u64, 0_u64, shard)
        return
      end
      scan_payload(Pointer(UInt8).new(from), finish &- from, base_only, 0_u64, 0_u64, shard)
    end

    # `scan_object`'s body, chunk resolved. Words in `[skip_lo, skip_hi)` are
    # not followed: `mark_from_children` passes the object's own block there,
    # every other caller an empty range, which the inline folds away.
    @[AlwaysInline]
    private def scan_block(chunk : ChunkHeader*, header : BlockHeader*, skip_lo : UInt64, skip_hi : UInt64,
                           shard : MarkShard? = nil) : Nil
      return if atomic_of(chunk, header)

      user = user_of(chunk, header).as(UInt8*)
      size = block_payload(chunk, header)
      return if size == 0
      base_only = !@allow_interior_pointers && size >= 4 && !type_id_plausible?(chunk, header)
      scan_payload(user, size, base_only, skip_lo, skip_hi, shard)
    end

    # The words of one payload, `size` bytes at `user`.
    @[AlwaysInline]
    private def scan_payload(user : UInt8*, size : UInt64, base_only : Bool, skip_lo : UInt64, skip_hi : UInt64,
                             shard : MarkShard? = nil) : Nil
      # A shared counter written per object by every helper is the line
      # parallel mark's scaling already paid for once; helpers count into
      # their own line and the master folds them in after the cycle.
      if @mark_parallel
        count_parallel_scanned_bytes(size, shard)
      else
        @mark_scanned_bytes &+= size
      end

      # No type map narrows this scan. `Gcry::Layout` keyed one off the
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
      # layout-miss types with mid-object pointers stay correct.
      #
      # This is a root-completeness heuristic on *heap edges*, not just on
      # ambient roots: an interior pointer stored inside a Slice / raw buffer is
      # dropped. It is also a second, silent consumer of type_id_plausible? —
      # so with @type_id_gate off, the type_id heuristic still steered marking
      # from here. @allow_interior_pointers (on by default; GCRY_DISABLE_INTERIOR) now
      # switches both off together, which is what makes `root_soundness=sound`
      # a true statement. See docs/SOUND-DEFAULTS.md. The callers take that
      # decision and pass it in as `base_only`.
      word = sizeof(Void*).to_u64
      words = size // word
      # The planted miss of `make mark-audit` (`mark_test_short_tid`).
      if (short = @mark_test_short_tid) != 0 && words > 0 && user.as(Int32*).value == short
        words -= 1
      end
      cursor = user.as(UInt64*)
      if @mark_edges_inline && skip_lo == skip_hi
        scan_edges_inline(cursor, words, base_only, shard)
        return
      end
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
        next if w >= skip_lo && w < skip_hi
        mark_impl(Pointer(Void).new(w), gate_type_id: false, base_only: base_only, source: RootSource::Heap)
      end
    end

    # Whether `scan_payload` may resolve heap edges itself, for the length of
    # one `mark_loop` (set and cleared there).
    @mark_edges_inline : Bool = false

    # The configurations in which `scan_edges_inline` gives exactly
    # `mark_impl_unlocked`'s answer for a word that lands in a small bitmap
    # chunk. Each term names a branch of that method the inline path leaves
    # out: the radix hit taken without `@index_lock` (only under the stop, and
    # not while the index audit counts lock skips); `occ` as the allocation
    # answer and the bitmap as the only mark (`bitmap_alloc`, which also
    # retires the header-mark union); the minor's nursery filter; first-mark
    # attribution; the misaligned-candidate filter; the thread-list tripwire;
    # and the double-push catcher.
    private def mark_edges_inline_allowed? : Bool
      {% if flag?(:gcry_hl_assert) %}
        return false
      {% end %}
      @world_stopped && !@index_audit && !@radix_l1.null? && @bitmap_alloc && @bitmap_marks &&
        !@minor_only && !@live_attr_roots && @scan_unaligned_candidates && !ThreadListWatch.armed?
    end

    # `scan_payload`'s loop with the candidate resolved in place rather than
    # through a `mark_impl_unlocked` call per word that passes the heap span.
    #
    # That call was most of the mark's instructions. Its frame carries a
    # 500-byte buffer (`report_thread_list_offer` inlines into it), so every
    # candidate saved and restored six registers; the radix shift went out of
    # line; and every `self` field was reloaded after each store, so the block
    # ordinal — a load of the size class and data offset, a checked multiply,
    # a bounds-checked table read — was derived three times, once each for
    # `block_allocated?`, `block_marked_in?` and `set_block_mark_in`. Here it
    # is derived once, with the table, the span and the radix fields in
    # registers. Serial Σ mark over 7 interleaved runs: Primes 774 → 592 ms,
    # JsonParsePure 744 → 498, JsonGenerate 812 → 540, JsonParseSerializable
    # 214 → 141, Binarytrees 104 → 70 (`bench/log/linux/2026-10-06-mark-cost/`).
    #
    # The mark bit is read before `occ`: a candidate that is already marked is
    # rejected either way, and on JsonParsePure 36% of them are, so their
    # `occ` line is never touched. Every candidate this does not handle in
    # full — not in the table, outside the chunk's blocks, a large or nursery
    # chunk — goes to `mark_impl`, which stays the authority.
    private def scan_edges_inline(cursor : UInt64*, words : UInt64, base_only : Bool, shard : MarkShard?) : Nil
      lo = @heap_min
      hi = @heap_max
      l1 = @radix_l1
      shift = @radix_granule_shift
      l2_mask = @radix_l2_mask
      hits = 0_u64
      p = cursor
      finish = cursor + words
      while p < finish
        w = p.value
        p += 1
        next if w < lo || w >= hi
        chunk = Heap.radix_entry(l1, shift, l2_mask, w)
        if chunk.null?
          mark_impl(Pointer(Void).new(w), gate_type_id: false, base_only: base_only, source: RootSource::Heap)
          next
        end
        cls = chunk.value.size_class
        bitmap_words = chunk.value.bitmap_words.to_u64
        data_start = chunk.address &+ chunk.value.data_offset
        chunk_end = chunk.address &+ chunk.value.mapped_bytes
        # `size_class` past the table covers large chunks (`UInt32::MAX`).
        if cls >= SIZE_CLASS_COUNT || bitmap_words == 0 ||
           (chunk.value.flags & ChunkHeader::Flags::NURSERY) != 0 || w < data_start || w >= chunk_end
          mark_impl(Pointer(Void).new(w), gate_type_id: false, base_only: base_only, source: RootSource::Heap)
          next
        end
        hits &+= 1
        index = cls.to_i32
        ordinal = Heap.block_ordinal(w &- data_start, @block_magic.unsafe_fetch(index))
        block_bytes = @block_bytes.unsafe_fetch(index)
        header_addr = data_start &+ ordinal &* block_bytes
        # The chunk's tail past its last whole block.
        next if header_addr &+ block_bytes > chunk_end
        occ = (chunk.as(UInt8*) + ChunkHeader::SIZE).as(UInt64*) + (ordinal >> 6)
        bit = 1_u64 << (ordinal & 63)
        mark = occ + bitmap_words
        next if (mark.value & bit) != 0
        next if (occ.value & bit) == 0
        header = Pointer(BlockHeader).new(header_addr)
        next if base_only && w != BlockHeader.user_from(header).address
        # `chunk_set_mark` with its relaxed pre-check already done above.
        Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Or, mark, bit, LLVM::AtomicOrdering::Monotonic, false)
        next if ChunkHeader.atomic?(chunk) || BlockHeader.atomic?(header)
        mark_stack_push(mark_entry(chunk, header), shard)
      end
      # `radix_note_fast_hit`, once per payload.
      @radix_fast_hits &+= hits unless @mark_parallel
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
      page = Gcry.os_map(Platform::PAGE_SIZE.to_u64)
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
        Gcry.os_unmap(page, Platform::PAGE_SIZE.to_u64)
      end
    end

    private def scan_object_for_nursery(header : BlockHeader*) : Nil
      return if BlockHeader.atomic?(header)
      chunk = chunk_containing(header.address)
      return unless chunk
      user = user_of(chunk, header).as(UInt8*)
      size = block_payload(chunk, header)
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
      size = block_payload(chunk, header)
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

    # Finalizable objects found on a cycle by `enqueue_unreachable_finalizers`,
    # cumulative: each one is reachable from its own fields, so it is never
    # finalized and never reclaimed. Boehm warns per object per collection;
    # this counts every sighting and prints at 1, 2, 4, 8, ...
    getter finalization_cycles : UInt64 = 0_u64

    # After mark, before sweep. Allocation-free (no Crystal Proc/closure).
    # World stopped; registry quiesced at stop_world (no concurrent mutate).
    # The mark stack is empty on entry: both callers have just drained it.
    #
    # Boehm's `GC_finalize`, for both orderings it is asked for
    # (`Finalizers::Order`): `GC_register_finalizer_ignore_self`, which is how
    # Crystal's stdlib registers every finalizer (`gc/boehm.cr`), and plain
    # `GC_register_finalizer` through the C ABI:
    #
    # 1. Disappearing links whose target is unmarked are cleared first, while
    #    the targets still look dead: a `WeakRef` to an object that only a
    #    dying finalizable reaches reads nil from here on, though the object
    #    is kept for that finalizer (Boehm's short links do the same).
    # 2. Ordering. For every unreachable finalizable, mark from its fields —
    #    not from the object itself, and under `IgnoreSelf` not through a
    #    pointer into its own block. A finalizable reached that way is not
    #    ready: one that will be
    #    finalized now still holds it, so it waits for a later collection and
    #    the holder's finalizer can still use it. A chain of n finalizes over n
    #    collections, holder first. One that its own fields reach is on a
    #    cycle and is never ready, as in Boehm — under `Normal`, a pointer to
    #    itself is such a way back.
    # 3. What is still unmarked is queued and *resurrected* (marked) so the
    #    sweep does not reclaim it before `run_pending`; otherwise
    #    Socket/Digest#finalize runs on freed memory (acik wrk SEGV). Its
    #    fields were marked in 2. Until its finalizer has run, every later
    #    collection marks it as a root (`mark_pending_finalizers`); the first
    #    one after that reclaims it if nothing else holds it.
    # 4. A link whose *location* is in a block that is still unmarked — a
    #    `WeakRef` that died itself — is dropped, without a write: its block
    #    is about to be reclaimed. Only now, so a `WeakRef` that a dying
    #    finalizable holds stays registered (Boehm's
    #    `GC_remove_dangling_disappearing_links`, also after the marking).
    #
    # Until 2026-10-05 step 2 was missing: every unreachable finalizable was
    # queued in one pass and they ran in table order, so a holder's finalizer
    # could find what it holds already finalized
    # (`process_spec/regression/17_ordered_finalization_spec.cr`).
    private def enqueue_unreachable_finalizers : Nil
      i = 0
      while i < @finalizers.link_count
        if unmarked_live_object?(@finalizers.link_object_at(i))
          @finalizers.clear_and_remove_link_at(i)
        else
          i += 1
        end
      end

      # Drained per object, serially, as Boehm's `GC_mark_fo` does: the cycle
      # check needs the closure of this object alone, and `mark_loop` would
      # start and stop the parallel pool once per finalizable. Marks only grow
      # across the loop, so which objects end up ready does not depend on the
      # table's order.
      n = @finalizers.entry_count
      i = 0
      while i < n
        obj = @finalizers.entry_object_at(i)
        if found = unmarked_live_block(obj)
          header, chunk = found
          mark_from_children(chunk, header, @finalizers.entry_order_at(i))
          serial_mark_drain
          note_finalization_cycle(obj) if block_marked_in?(chunk, header)
        end
        i += 1
      end

      i = 0
      while i < @finalizers.entry_count
        obj = @finalizers.entry_object_at(i)
        if found = unmarked_live_block(obj)
          header, chunk = found
          count_type_id_false_negative(obj, chunk, header)
          @finalizers.queue_and_remove_entry_at(i)
          # Its fields were marked above; only its own mark is missing, so
          # set it rather than push the object to be scanned a second time.
          #
          # Research only (`finalizer_resurrect = false`,
          # `GCRY_FINALIZER_NO_RESURRECT=1`): skip the object's own
          # resurrection, so the sweep reclaims its block and the callback
          # runs on freed memory — the pre-Boehm-rule behaviour.
          # `make finalizer-complex --broken` requires the callback to find
          # its object gone.
          if @finalizer_resurrect
            set_block_mark_in(chunk, header)
            note_first_mark(chunk, header, RootSource::Heap) if @live_attr_roots
          end
        else
          i += 1
        end
      end

      # Until 2026-10-05 this step was missing: the row outlived its
      # `WeakRef`, and when the target died later the null of step 1 went
      # into whatever had reused the `WeakRef`'s block — all 2000 dead
      # `WeakRef`s of `process_spec/regression/20_dangling_weak_link_spec.cr`
      # zeroed a word of a reused block.
      i = 0
      while i < @finalizers.link_count
        if dead_link_location?(@finalizers.link_location_at(i))
          @finalizers.remove_link_at(i)
        else
          i += 1
        end
      end
    end

    # The block holding a link location is dead: unmarked now, or already
    # freed (`GC.free` on the holder, which `notice_reclaim` does not catch —
    # it matches link *targets*). A location outside the heap (a C slot, a
    # static) resolves to no block and stays registered.
    private def dead_link_location?(location : Void*) : Bool
      found = find_block_with_chunk(location)
      return false unless found
      header, chunk = found
      return true unless block_allocated?(chunk, header)
      # During a minor an old holder is unmarked and alive.
      return false if @minor_only && !BlockHeader.nursery?(header)
      !block_marked_in?(chunk, header)
    end

    # Push what *header*'s object points at, leaving the object itself
    # unmarked. Under `IgnoreSelf` (Boehm's `GC_ignore_self_finalize_mark_proc`)
    # a word that resolves into the object's own block is skipped —
    # `XML::Document` holds `@document = self`, and following that would make
    # every document a cycle. A longer way back (A -> X -> A) is still
    # followed, and is a cycle. The range is the one `find_block_with_chunk`
    # resolves to this block. Under `Normal` (`GC_normal_finalize_mark_proc`)
    # every word is followed, and a pointer to itself marks the object.
    private def mark_from_children(chunk : ChunkHeader*, header : BlockHeader*, order : Finalizers::Order) : Nil
      if order.normal?
        scan_block(chunk, header, 0_u64, 0_u64)
        return
      end
      lo = header.address
      hi = if ChunkHeader.large?(chunk)
             user_of(chunk, header).address &+ ChunkHeader.large_payload(chunk)
           else
             lo &+ @block_bytes[chunk.value.size_class.to_i32]
           end
      scan_block(chunk, header, lo, hi)
    end

    # Root phase: every object queued for finalization and its callback's
    # closure data, until its finalizer has run (`Registry#each_pending`).
    # Until 2026-10-06 a queued object was kept only by the collection that
    # queued it; a second one before `run_pending` — an idle collection, or
    # another thread's — swept it and queued what it held ahead of it
    # (`process_spec/regression/26_pending_finalizer_root_spec.cr`).
    private def mark_pending_finalizers : Nil
      @finalizers.each_pending do |object, data|
        mark_candidate(object)
        mark_candidate(data) unless data.null?
      end
    end

    private def note_finalization_cycle(obj : Void*) : Nil
      @finalization_cycles &+= 1
      count = @finalization_cycles
      return unless count & (count &- 1) == 0
      buf = uninitialized UInt8[RawOut::LIMIT]
      len = RawOut.append(buf.to_unsafe, 0, "gcry: finalization cycle involving 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, obj.address)
      len = RawOut.append(buf.to_unsafe, len,
        " — an object with a finalizer reaches itself through its own fields, so neither its " \
        "finalizer runs nor its memory is reclaimed while that holds (ordered finalization, as " \
        "Boehm's). Sightings so far: ")
      len = RawOut.append_u64(buf.to_unsafe, len, count)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # *obj*'s block and chunk when it is allocated, eligible this collection,
    # and unmarked; nil otherwise.
    private def unmarked_live_block(obj : Void*) : {BlockHeader*, ChunkHeader*}?
      return nil if obj.null?
      found = find_object_with_chunk(obj)
      return nil unless found
      header, chunk = found
      return nil if BlockHeader.free?(header)
      # During generational minor, old objects are intentionally unmarked.
      # Only nursery deaths may enqueue finalizers / clear WeakRef links.
      return nil if @minor_only && !BlockHeader.nursery?(header)
      # The heap-local mark check, not the static `BlockHeader.marked?`: under
      # `GCRY_BITMAP=1` the header generation is not where the marks are, and
      # the static reader would answer for the wrong representation.
      return nil if block_marked_in?(chunk, header)
      found
    end

    private def unmarked_live_object?(obj : Void*) : Bool
      found = unmarked_live_block(obj)
      return false unless found
      count_type_id_false_negative(obj, found[1], found[0])
      true
    end

    # False-negative counter: gate rejected the ambient pointer that pointed
    # here, but a different root still walked this object. If the page is
    # also blacklisted (we previously declared similar addresses false), this
    # is exactly the UAF vector the gate is supposed to prevent — record it
    # so a production heap can alert on a non-zero rate.
    private def count_type_id_false_negative(obj : Void*, chunk : ChunkHeader*, header : BlockHeader*) : Nil
      if @blacklist_enabled && blacklisted_page?(obj.address) && type_id_plausible?(chunk, header)
        @type_id_root_false_negatives += 1
      end
    end
  end
end
