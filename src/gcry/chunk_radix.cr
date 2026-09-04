require "./block"

module Gcry
  class Heap
    # Address → chunk in two dependent loads, replacing a binary search.
    #
    # `chunk_containing` costs a `log n` search over the address-sorted index
    # for every candidate word the conservative scan accepts, plus a one-slot
    # cache that only helps when successive candidates land in the same chunk.
    # On a JSON mark storm they mostly do not.
    #
    # ## Shape
    #
    # Two levels, Boehm's `GC_top_index` idea with gcry's constraints:
    #
    #   L1[(addr >> 32) & 0xFFFF]        -> L2 table for that 4 GiB region
    #   L2[(addr >> granule_shift) & m]  -> ChunkHeader*
    #
    # The granule is the **host page size**, and that makes entries *exact*
    # rather than merely usually-right. Chunk bases are page-aligned (`mmap`
    # with a NULL hint) and chunk sizes are page multiples — `small_chunk_bytes`
    # is validated `% 4096 == 0` and large mappings are `align_up`ed — so
    # **every granule belongs to exactly one chunk and no two chunks ever share
    # an entry**. The page size is also the largest granule for which that
    # holds.
    #
    # A coarser table was considered and rejected for that reason: at 64 KiB
    # granules a 128 KiB page-aligned chunk straddles, entries become ambiguous,
    # roughly a quarter of cold lookups would fall back to the binary search,
    # and that is most of the win. It is smaller, not cheaper.
    #
    # ## Why this is plain ivars on `Heap` and not a class of its own
    #
    # It *was* a class, and that segfaulted every `-Dgc_none` binary at boot,
    # before a single user allocation. `Heap#initialize` runs inside `GC.init`
    # under the process GC, so allocating anything on the managed heap there —
    # including the object header for a wrapper whose own storage is `mmap`ed —
    # faults on a heap that does not exist yet. Same reason the env reads use
    # `LibC.getenv` rather than `ENV[]`, and the same reason `size_classes.cr`
    # refuses runtime constant initializers. The comment stating that constraint
    # was three lines above the line that broke it.
    #
    # A `struct` would have fixed the allocation and introduced a worse bug:
    # `@radix.try(&.insert(...))` on a nilable struct mutates a *copy*, so every
    # insert would be discarded and every counter would read zero, silently.
    #
    # The page size is read with a direct `sysconf` for the same class of
    # reason: `Platform.host_page_size` returns a constant initialised at
    # runtime, which Crystal implements with `once`, and `once` needs a Fiber.
    #
    # ## Cost, and the estimate that was wrong
    #
    # L1 is 64 Ki entries = 512 KiB of reservation. L2 is one entry per page of
    # a 4 GiB region — 8 MiB reserved at 4 KiB pages, 2 MiB at 16 KiB. Both are
    # `mmap`ed and lazily faulted.
    #
    # That used to read "resident cost ~8 bytes per page of live heap, 0.2% of
    # the heap". The arithmetic was right and the assumption was not. Measured
    # (`bench/log/linux/2026-09-03-simdgc-chunk-radix-ab/`), post-GC RSS rose
    # **+16-21%** on Kemal, and smaps named the cause:
    #
    #   7fd07f993000-7fd080193000  Size: 8192 kB  Rss: 2048 kB  AnonHugePages: 2048 kB
    #
    # With THP in `always`, a single touched entry faults a **2 MiB** huge page,
    # so resident cost stops tracking the live heap and becomes ~2 MiB per 4 GiB
    # region holding any chunk. On a 13 MB heap that is 160x the old estimate.
    # It is bounded — five successive loads plateaued at 2172 KiB — but it is a
    # fixed tax paid by every process, which is exactly the wrong shape for a
    # collector judged on RSS x Boehm.
    #
    # So the tables are `MADV_NOHUGEPAGE`d, the same policy and the same reason
    # as `map_chunk` (heap.cr): base pages keep RSS proportional to what is
    # actually touched. `GCRY_RADIX_THP=1` opts back in, because the huge page
    # also gives the whole table one TLB entry and some of the mark win may be
    # paid for by exactly the pages this gives up — that A/B is the knob's
    # reason to exist.
    #
    # ## Lifetime, which is the whole safety argument
    #
    # A lookup ends in `ChunkHeader.contains?`, which **dereferences the
    # chunk**. If a reader could race an `index_remove` + `munmap`, that read
    # would fault in an unmapped VMA.
    #
    # So this table introduces no lifetime protocol of its own. Entries are
    # written and cleared inside the very same `@index_lock` critical sections
    # as the sorted index (`index_insert_locked` / `index_remove_locked`), which
    # means a radix entry is valid exactly when a sorted-index entry is. The
    # locking discipline of `chunk_containing` is **unchanged**: it still takes
    # `@index_lock` unless `@world_stopped`, and the fast path is used under
    # both. A reader safe against the binary search is safe against this table,
    # for the same reason and to the same extent.
    #
    # The win is unaffected, because the mark phase — essentially every lookup —
    # already runs inside STW and so already skips the lock; what changes is
    # `log n` becoming two loads. The rule that `@collecting` alone is *not*
    # enough to skip the lock was bought with a bug
    # (`2026-07-31-ec4-index-lock-collecting`) and is not re-litigated here.

    RADIX_L1_BITS  = 16
    RADIX_L1_SIZE  = 1 << RADIX_L1_BITS
    RADIX_L1_MASK  = RADIX_L1_SIZE - 1
    RADIX_L1_SHIFT = 32

    # A chunk spanning more than this many granules is left out of the table and
    # resolved by the binary search instead. Without it a 1 GiB large object
    # would be 262,144 pointer stores on map and as many again on unmap, inside
    # `@alloc_lock`, turning an O(chunks) path into an O(bytes) one. 1024
    # granules is 4 MiB at 4 KiB pages, which covers every ordinary large
    # object; the giants that exceed it are rare enough that a `log n` search is
    # the right price.
    RADIX_MAX_GRANULES = 1024

    # `GCRY_RADIX_THP=1`: leave the tables eligible for transparent huge pages.
    # Off by default — see the cost note above.
    @radix_thp : Bool = false
    @radix_l1 : Pointer(Pointer(ChunkHeader*)) = Pointer(Pointer(ChunkHeader*)).null
    @radix_granule_shift : Int32 = 0
    @radix_l2_mask : UInt64 = 0_u64
    @radix_l2_bytes : UInt64 = 0_u64

    getter radix_fast_hits : UInt64 = 0_u64
    getter radix_slow_lookups : UInt64 = 0_u64
    # Chunks too large to be worth publishing, resolved by the binary search.
    getter radix_oversize_skips : UInt64 = 0_u64

    def chunk_radix? : Bool
      !@radix_l1.null?
    end

    # Only before any chunk exists: an already-mapped chunk would never be
    # published into the table, so it would resolve by fallback forever while
    # the counters claimed otherwise.
    def chunk_radix=(value : Bool) : Bool
      return value if value == chunk_radix?
      unless @chunks.null?
        raise ArgumentError.new("chunk_radix cannot change once chunks are mapped")
      end
      value ? radix_init : radix_destroy
      value
    end

    protected def radix_init : Nil
      return unless @radix_l1.null?
      @radix_thp = Heap.radix_thp_from_env
      # Direct sysconf: `Platform.host_page_size` is a `once`-initialised
      # constant and this can run inside GC.init. See the note above.
      raw = LibC.sysconf(LibC::SC_PAGESIZE)
      page = raw > 0 ? raw.to_u64 : 4096_u64
      shift = 0
      while (1_u64 << shift) < page
        shift += 1
      end
      entries = 1_u64 << (RADIX_L1_SHIFT - shift)

      l1 = radix_map_zeroed(RADIX_L1_SIZE.to_u64 * 8)
      return if l1.null?

      @radix_granule_shift = shift
      @radix_l2_mask = entries - 1
      @radix_l2_bytes = entries * 8
      @radix_l1 = l1.as(Pointer(Pointer(ChunkHeader*)))
    end

    protected def radix_destroy : Nil
      l1 = @radix_l1
      return if l1.null?
      RADIX_L1_SIZE.times do |i|
        l2 = l1[i]
        LibC.munmap(l2.as(Void*), LibC::SizeT.new(@radix_l2_bytes)) unless l2.null?
      end
      LibC.munmap(l1.as(Void*), LibC::SizeT.new(RADIX_L1_SIZE.to_u64 * 8))
      @radix_l1 = Pointer(Pointer(ChunkHeader*)).null
    end

    # Two dependent loads and a null check.
    #
    # The caller still applies `ChunkHeader.contains?`, but that is **defence in
    # depth, not correctness**: granules are exact, so a non-null entry already
    # names the only chunk that address can belong to. Removing the check does
    # not change a single answer — measured, by removing it and watching
    # `spec/chunk_radix_spec.cr` stay green. It is kept because it costs two
    # loads already in cache, it is the one thing standing between a corrupted
    # entry and a wrong chunk, and the L1 index drops address bits above 48 that
    # no current platform hands out.
    @[AlwaysInline]
    protected def radix_lookup(addr : UInt64) : ChunkHeader*
      l1 = @radix_l1
      return Pointer(ChunkHeader).null if l1.null?
      l2 = l1[(addr >> RADIX_L1_SHIFT) & RADIX_L1_MASK]
      return Pointer(ChunkHeader).null if l2.null?
      l2[(addr >> @radix_granule_shift) & @radix_l2_mask]
    end

    @[AlwaysInline]
    protected def radix_note_fast_hit : Nil
      @radix_fast_hits &+= 1
    end

    @[AlwaysInline]
    protected def radix_note_slow : Nil
      @radix_slow_lookups &+= 1
    end

    # Publish a chunk. Caller holds the lock that guards the sorted index.
    protected def radix_insert(chunk : ChunkHeader*) : Nil
      radix_each_granule(chunk) { |l2, idx| l2[idx] = chunk }
    end

    # Retract a chunk, before the caller's `munmap`.
    protected def radix_remove(chunk : ChunkHeader*) : Nil
      radix_each_granule(chunk) do |l2, idx|
        # Only clear an entry that still names this chunk. Granules are exact,
        # so this cannot fire from a neighbour sharing a boundary — but a chunk
        # mapped at a freed chunk's address would own the entry by then, and
        # clearing it out from under the new owner would strand it on the slow
        # path for its whole life. The ordering that makes that impossible
        # (remove, then munmap, then any remap) is a property of the callers, so
        # this does not rely on it.
        l2[idx] = Pointer(ChunkHeader).null if l2[idx] == chunk
      end
    end

    private def radix_each_granule(chunk : ChunkHeader*, & : (ChunkHeader**, UInt64) ->) : Nil
      l1 = @radix_l1
      return if l1.null?
      base = chunk.address
      limit = base &+ chunk.value.mapped_bytes
      first = base >> @radix_granule_shift
      last = (limit &- 1) >> @radix_granule_shift
      if last &- first &+ 1 > RADIX_MAX_GRANULES
        @radix_oversize_skips &+= 1
        return
      end

      g = first
      while g <= last
        addr = g << @radix_granule_shift
        slot = l1 + ((addr >> RADIX_L1_SHIFT) & RADIX_L1_MASK)
        l2 = slot.value
        if l2.null?
          mapped = radix_map_zeroed(@radix_l2_bytes)
          return if mapped.null?
          l2 = mapped.as(ChunkHeader**)
          slot.value = l2
        end
        yield l2, (addr >> @radix_granule_shift) & @radix_l2_mask
        g &+= 1
      end
    end

    # `mmap`, never the managed heap: this is collector metadata, and the
    # collector's hard rule is that it allocates nothing the collector itself
    # manages. Zeroed by the kernel and lazily faulted, which is what keeps a
    # multi-MiB reservation cheap.
    private def radix_map_zeroed(bytes : UInt64) : Void*
      ptr = LibC.mmap(Pointer(Void).null, LibC::SizeT.new(bytes),
        LibC::PROT_READ | LibC::PROT_WRITE,
        LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS, -1, 0)
      return Pointer(Void).null if Gcry.mmap_failed?(ptr)
      # See the cost note above: one touched entry otherwise faults a whole
      # 2 MiB huge page and the table's RSS stops tracking the live heap.
      {% if flag?(:linux) %}
        unless @radix_thp
          LibC.madvise(ptr, LibC::SizeT.new(bytes), Platform::MADV_NOHUGEPAGE)
        end
      {% end %}
      ptr
    end
  end
end
