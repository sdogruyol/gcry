# The memory an out-of-memory report needs, set aside before it is needed.
#
# Reporting an allocation failure allocates: the message is a `String`, the
# error an object, and Crystal's `raise` takes a `LibUnwind::Exception` from
# the managed heap on every raise and a `CallStack` on the first. When the
# heap has nothing left in the classes those land in, the report fails, and a
# failure inside the report asks the allocator again, fails again and reports
# again until the stack overflows — a SIGSEGV where the program was owed an
# `OutOfMemoryError`. Measured 2026-09-24 with every small class exhausted
# (`GCRY_OOM_TEST_EXHAUSTED=1`): every run.
#
# So a thread inside `oom!` allocates from a heap of its own:
#
#   * one anonymous region mapped at boot and never touched until a report
#     needs it — address space and, under strict overcommit, commit charge,
#     but no RSS. Chunks are laid on it with no syscall at all, so neither
#     `RLIMIT_AS` nor the commit limit can refuse them at the moment they are
#     needed;
#   * a cursor set of its own, used only by threads that are reporting, which
#     takes blocks only from those chunks (`ChunkHeader::Flags::RESERVE`);
#   * chunks the ordinary pool never takes and the sweep never releases. A
#     report's objects are ordinary scanned, collectable objects; the chunks
#     stay for the next report. The program's own allocations cannot drain it.
#
# Bitmap allocator without a nursery — the default. `GCRY_OOM_RESERVE_KB=0`
# turns it off: the red arm of `make oom-no-hang`.

{% unless flag?(:win32) %}
  lib LibC
    fun abort : NoReturn
  end
{% end %}

module Gcry
  class Heap
    OOM_RESERVE_DEFAULT_KB = 4096_u64

    # Depth of `oom!` frames on this thread; the reserve is for the thread
    # that is reporting, not for its neighbours.
    @[ThreadLocal]
    @@oom_depth : Int32 = 0

    @oom_reserve_base = 0_u64
    @oom_reserve_size = 0_u64
    # Bytes of the region laid out as chunks so far, under the lock below.
    @oom_reserve_used = 0_u64
    # Serialises reserve takes across classes; each taker already holds its
    # class lock. Order: class → reserve → chunk list → index.
    @oom_reserve_lock = Crystal::SpinLock.new
    @oom_reserve_set = Pointer(CursorSet).null
    # Set by the first `oom!`; read only by the research arm below.
    @oom_seen = false

    # Blocks handed out from the reserve. Best effort across threads.
    getter oom_reserve_allocations : UInt64 = 0_u64

    # Research only — `GCRY_OOM_TEST_EXHAUSTED=1`: once one allocation has
    # failed, fail every small allocation the reserve does not serve, as a
    # heap with nothing left in any size class would. What makes the report's
    # own allocations fail on every run, whatever happens to be left over in
    # the classes it uses — the arm `make oom-no-hang` judges.
    property oom_test_exhausted : Bool = false

    def oom_reserve_bytes : UInt64
      @oom_reserve_size
    end

    def oom_reserve_chunks_used : UInt64
      @oom_reserve_used // @small_chunk_bytes
    end

    # Map *bytes* for reports. Once, at boot, from the process GC's
    # configuration.
    def setup_oom_reserve(bytes : UInt64) : Nil
      return if @oom_reserve_size != 0 || !@bitmap_alloc || @nursery_enabled
      return if bytes < @small_chunk_bytes
      bytes -= bytes % @small_chunk_bytes
      ptr = mmap_anonymous(bytes)
      return if Gcry.mmap_failed?(ptr)
      set = alloc_cursor_set
      if set.null?
        Gcry::OS.munmap(ptr, LibC::SizeT.new(bytes))
        return
      end
      # Never the hit path, and pinned rather than retired at a stop-the-world,
      # as the shared fallback set is: several reporting threads share it.
      set.value.no_hit_path = 1_u8
      set.value.state = CursorSet::STATE_LIVE
      @oom_reserve_base = ptr.address
      @oom_reserve_size = bytes
      @oom_reserve_set = set
    end

    # Serve this allocation from the reserve: the thread is reporting.
    @[AlwaysInline]
    protected def oom_reserve_active? : Bool
      @@oom_depth > 0 && !@oom_reserve_set.null?
    end

    # The research arm: refuse, once an allocation has failed, anything the
    # reserve is not serving.
    @[AlwaysInline]
    protected def oom_test_refuse? : Bool
      @oom_test_exhausted && @oom_seen && !oom_reserve_active?
    end

    # A chunk of class *index* for the reserve's cursor: a laid-out one with
    # room in it, or the next piece of the region. Class lock held.
    protected def oom_reserve_take_chunk(index : Int32, atomic : Bool) : ChunkHeader*
      @oom_reserve_lock.sync do
        offset = 0_u64
        while offset < @oom_reserve_used
          chunk = Pointer(ChunkHeader).new(@oom_reserve_base &+ offset)
          offset &+= @small_chunk_bytes
          next unless bitmap_pool_candidate?(chunk, index, atomic, reserve: true)
          ChunkHeader.set_cursor(chunk, true)
          return chunk
        end
        return Pointer(ChunkHeader).null if @oom_reserve_used &+ @small_chunk_bytes > @oom_reserve_size
        flags = ChunkHeader::Flags::CURSOR | ChunkHeader::Flags::RESERVE
        flags |= ChunkHeader::Flags::ATOMIC if atomic
        chunk = map_chunk(@small_chunk_bytes, index.to_u32, flags,
          Pointer(Void).new(@oom_reserve_base &+ @oom_reserve_used))
        @oom_reserve_used &+= @small_chunk_bytes unless chunk.null?
        chunk
      end
    end

    # Out of memory while reporting out of memory: the prebuilt error's own
    # raise could not allocate its unwind record. Nothing is left that can
    # raise, so say so without allocating and stop, instead of recursing
    # until the stack overflows.
    private def oom_abort : NoReturn
      buf = uninitialized UInt8[RawOut::LIMIT]
      n = RawOut.append(buf.to_unsafe, 0, "gcry: out of memory while reporting out of memory; aborting\n")
      RawOut.flush(buf.to_unsafe, n)
      LibC.abort
    end
  end
end
