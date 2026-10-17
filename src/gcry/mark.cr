require "./block"

module Gcry
  # Growable mark stack backed by mmap (not the managed heap).
  class MarkStack
    INITIAL_BYTES = 262144_u64 # 256 KiB — avoid grow under JSON mark storms

    # Entries of the batch buffer (`batch_buffer`), 8 KiB.
    BATCH_ENTRIES = 1024

    @base : Void* = Pointer(Void).null
    @capacity : Int32 = 0
    @size : Int32 = 0
    @mapped_bytes : UInt64 = 0
    @batch : Void** = Pointer(Void*).null

    def initialize
      grow(INITIAL_BYTES)
    end

    def finalize
      destroy
    end

    def destroy : Nil
      unless @batch.null?
        Gcry.os_unmap(@batch.as(Void*), BATCH_ENTRIES.to_u64 * sizeof(Void*))
        @batch = Pointer(Void*).null
      end
      return if @base.null?
      Gcry.os_unmap(@base, @mapped_bytes.to_u64)
      @base = Pointer(Void).null
      @capacity = 0
      @size = 0
      @mapped_bytes = 0
    end

    # `BATCH_ENTRIES` words for the serial drain to scan a batch from
    # (`Heap#serial_mark_drain`), mapped on first use; null if the map
    # failed. Mapped rather than on the collector's stack: there 8 KiB of
    # block addresses would widen the frame the entry and exit scrubs have to
    # cover (`Heap#run_collection`) by more than twice.
    def batch_buffer : Void**
      if @batch.null?
        ptr = Gcry.os_map(BATCH_ENTRIES.to_u64 * sizeof(Void*))
        @batch = ptr.as(Void**) unless Gcry.mmap_failed?(ptr)
      end
      @batch
    end

    # Up to *cap* entries off the top into *into*, newest first, as that many
    # `pop`s would return them; the count.
    def pop_into(into : Void**, cap : Int32) : Int32
      n = @size < cap ? @size : cap
      i = 0
      while i < n
        into[i] = entries[@size &- 1 &- i]
        i &+= 1
      end
      @size &-= n
      n
    end

    def clear : Nil
      @size = 0
    end

    def empty? : Bool
      @size == 0
    end

    # Entries held. Read under the lock that guards the stack.
    def size : Int32
      @size
    end

    # `empty?` for a reader that does not hold the lock guarding the stack:
    # a parallel-mark worker deciding whether a pop is worth taking that lock.
    # A stale answer only delays it. The load is atomic so it is redone on
    # every call rather than hoisted out of the caller's spin.
    def empty_unlocked? : Bool
      Atomic::Ops.load(pointerof(@size), LLVM::AtomicOrdering::Monotonic, true) == 0
    end

    # One word per entry, deliberately.
    #
    # Phase 7.6 first tried carrying the chunk beside the header, per the plan's
    # decision 5, so `scan_object` would not have to re-resolve it. Measured, that
    # was **+13.4% on phase_mark** (t=62.9) purely from doubling this stack —
    # more than the per-object `chunk_containing` it was meant to avoid. The
    # stack is hot and its width matters more than the lookup does. So the
    # trace's own pushes carry the block's size class in the entry's top byte
    # instead, and `scan_object` resolves the chunk only for an untagged entry
    # (`Heap::MARK_ENTRY_TAG_SHIFT`, collect_mark.cr). Entries are opaque here.
    def push(header : BlockHeader*) : Nil
      if @size >= @capacity
        grow(@mapped_bytes * 2)
      end
      entries[@size] = header.as(Void*)
      @size += 1
    end

    def pop : BlockHeader*
      raise "mark stack underflow" if @size == 0
      @size -= 1
      entries[@size].as(BlockHeader*)
    end

    private def entries : Void**
      @base.as(Void**)
    end

    private def grow(bytes : UInt64) : Nil
      ptr = Gcry.os_map(bytes)
      raise OutOfMemoryError.new("mark stack mmap failed") if Gcry.mmap_failed?(ptr)

      new_capacity = (bytes // sizeof(Void*)).to_i32
      unless @base.null?
        @base.as(Void**).copy_to(ptr.as(Void**), @size)
        Gcry.os_unmap(@base, @mapped_bytes.to_u64)
      end

      @base = ptr
      @mapped_bytes = bytes
      @capacity = new_capacity
    end
  end
end
