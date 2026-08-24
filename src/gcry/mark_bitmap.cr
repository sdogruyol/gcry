# Side mark bitmap (opt-in via `-Dgcry_side_bitmap`): one bit per word-aligned
# heap address, stored in mmap'd regions outside the managed heap. Default is
# in-header MARK — the bitmap path removes RMW on BlockHeader on every mark
# candidate and lets `clear_all_marks` become a single `memset(0)`, at the cost
# of a large side mmap (Linux HTTP A/B: ~9× RSS vs ~1× header marks).
#
# Layout:
#   - `@base`, `@base_addr`, `@capacity_bytes` describe the current mapping.
#   - `@base_addr` is the heap's lowest mapped byte; bit 0 corresponds to that
#     address. Word alignment of pointers is enforced by the callers (already
#     done in mark_impl_unlocked, mark_noscan_unlocked, scan_object_for_nursery,
#     scan_range_for_barrier_pointers).
#   - Each mmap region covers a power-of-two address range. When the heap
#     grows past the current region, the bitmap is re-laid-out over a larger
#     single mapping (uncommon; size class 256 KiB chunks amortize the cost).
#
# Reset semantics:
#   - `reset(lo, hi)` sets every bit for [lo, hi) word-aligned addresses to 0.
#     Used in `clear_all_marks` over the full heap and `clear_nursery_marks`
#     over nursery chunks only.

require "c/sys/mman"

module Gcry
  # Process-wide (or per-Heap) side mark bitmap. One instance per Heap.
  # The bitmap is stored in its own mmap, separate from the managed heap, so
  # allocating it never recurses into the collector.
  class MarkBitmap
    @@retain_old = false
    @@retired = 0_u64

    def self.retain_old=(v : Bool)
      @@retain_old = v
    end

    def self.retired : UInt64
      @@retired
    end

    INITIAL_BYTES = 65536_u64 # 64 KiB — covers ~512 KiB of managed heap (1 bit per word)

    @base : UInt8* = Pointer(UInt8).null
    @base_addr : UInt64 = 0_u64      # heap address that corresponds to bit 0
    @capacity_bytes : UInt64 = 0_u64 # mmap size in bytes; covers @capacity_bytes * 8 words
    @mapped_bytes : UInt64 = 0_u64   # actual mmap size (rounded up to page)

    def initialize
      # Initialize the bitmap mapped to a placeholder zero range; relocate
      # at first heap growth. capacity covers INITIAL_BYTES * 8 word addresses
      # (≈ 512 KiB of managed heap) which absorbs the very first allocation.
      relocate(0_u64, INITIAL_BYTES)
    end

    def finalize
      destroy
    end

    def destroy : Nil
      base_to_unmap = @base
      mapped_to_unmap = @mapped_bytes
      # Null the live fields FIRST so concurrent readers in `marked?` short
      # out on `@base.null?` instead of dereferencing the about-to-be-unmapped
      # mapping. The remaining unmap happens after the snapshot is no longer
      # visible to any reader that re-reads @base under the protection of
      # `current_mark_bitmap` being cleared by the owning Heap.
      @base = Pointer(UInt8).null
      @base_addr = 0_u64
      @capacity_bytes = 0_u64
      @mapped_bytes = 0_u64
      if !base_to_unmap.null?
        LibC.munmap(base_to_unmap.as(Void*), LibC::SizeT.new(mapped_to_unmap))
      end
    end

    # Remap the bitmap to cover [base_addr, base_addr + capacity_bytes * 8).
    # Used at collect start and when the heap grows past the current range.
    # Preserves existing bits that still fall inside the new range.
    #
    # When the required capacity is *smaller* than the current mapping, the
    # bitmap is shrunk: a new smaller mmap replaces the old one (one syscall)
    # and the old pages are released.  This prevents RSS from accumulating
    # when the heap range contracts after freeing many chunks.
    #
    # Concurrency: pointer reassignment happens BEFORE unmap of the old mapping
    # so other threads always see either the old (mapped) or the new (mapped)
    # bitmap — never a stale pointer to an unmapped region. Word-aligned pointer
    # stores are atomic on every supported architecture, so a parallel reader
    # sees one or the other.
    #
    # The optional *mirror* block is invoked AFTER the new mapping is published
    # so the calling Heap can mirror (base, base_addr, cap_bits) into its own
    # hot fields without an extra round-trip through `MarkBitmap#marked?`.
    def relocate(base_addr : UInt64, capacity_bytes : UInt64, & : (UInt64*, UInt64, UInt64) ->) : Nil
      target = capacity_bytes
      target = INITIAL_BYTES if target < INITIAL_BYTES
      target = next_power_of_two(target) if target > INITIAL_BYTES

      if @base.null?
        # First allocation — no old mapping to preserve.
        new_base = mmap_anonymous(target)
        raise OutOfMemoryError.new("mark bitmap mmap failed") if Gcry.mmap_failed?(new_base.as(Void*))
        @base = new_base
        @mapped_bytes = target
        @capacity_bytes = target
        @base_addr = base_addr
        yield new_base.as(UInt64*), base_addr, target.to_u64 * 8_u64
      elsif target == @capacity_bytes && base_addr == @base_addr
        # Exact same size and origin — nothing to do.
        yield @base.as(UInt64*), base_addr, @capacity_bytes.to_u64 * 8_u64
      elsif target > @capacity_bytes
        # Grow: allocate new (larger) mapping, copy overlapping bits from old.
        new_base = mmap_anonymous(target)
        raise OutOfMemoryError.new("mark bitmap mmap failed") if Gcry.mmap_failed?(new_base.as(Void*))
        old_base = @base
        old_mapped = @mapped_bytes
        @base.copy_to(new_base, @capacity_bytes.to_i32)
        @base = new_base
        @mapped_bytes = target
        @capacity_bytes = target
        @base_addr = base_addr
        # Retiring rather than freeing, when asked. `update_heap_bounds_after_unmap`
        # resizes this from two places that do not agree about locking: the
        # mutator paths hold `@alloc_lock`, the in-STW path does not — and a
        # mutator suspended mid-resize still holds a pointer into the old
        # mapping. `GCRY_BITMAP_RETAIN_OLD=1` keeps the old mapping to find out
        # whether that is what faults.
        if @@retain_old
          @@retired &+= 1
        else
          LibC.munmap(old_base.as(Void*), LibC::SizeT.new(old_mapped))
        end
        yield new_base.as(UInt64*), base_addr, target.to_u64 * 8_u64
      elsif target < @capacity_bytes && base_addr == @base_addr
        # Shrink: allocate new (smaller) mapping, copy valid bits from old.
        new_base = mmap_anonymous(target)
        raise OutOfMemoryError.new("mark bitmap mmap failed") if Gcry.mmap_failed?(new_base.as(Void*))
        old_base = @base
        old_mapped = @mapped_bytes
        if target > 0
          old_base.copy_to(new_base, target.to_i32)
        end
        @base = new_base
        @mapped_bytes = target
        @capacity_bytes = target
        # base_addr unchanged
        # Retiring rather than freeing, when asked. `update_heap_bounds_after_unmap`
        # resizes this from two places that do not agree about locking: the
        # mutator paths hold `@alloc_lock`, the in-STW path does not — and a
        # mutator suspended mid-resize still holds a pointer into the old
        # mapping. `GCRY_BITMAP_RETAIN_OLD=1` keeps the old mapping to find out
        # whether that is what faults.
        if @@retain_old
          @@retired &+= 1
        else
          LibC.munmap(old_base.as(Void*), LibC::SizeT.new(old_mapped))
        end
        yield new_base.as(UInt64*), base_addr, target.to_u64 * 8_u64
      else
        # Same size, base_addr shifted — old bits are at wrong offsets.
        @base_addr = base_addr
        zero_all
        yield @base.as(UInt64*), base_addr, @capacity_bytes.to_u64 * 8_u64
      end
    end

    # Overload for callers that do not need the (base, base_addr, cap_bits)
    # mirror (e.g. MarkBitmap#initialize before any heap is attached).
    def relocate(base_addr : UInt64, capacity_bytes : UInt64) : Nil
      relocate(base_addr, capacity_bytes) { |_b, _a, _c| nil }
    end

    # Test, set, clear — nil-safe and fast (constant time, no syscalls).
    def marked?(addr : UInt64) : Bool
      return false if @base.null?
      bit_index = addr - @base_addr
      return false if bit_index >= @capacity_bytes.to_u64 * 8
      word_index = bit_index >> 6
      bit = (bit_index & 63).to_i32
      ((@base.as(UInt64*)[word_index] >> bit) & 1_u64) != 0
    end

    def set(addr : UInt64) : Nil
      return if @base.null?
      bit_index = addr - @base_addr
      return if bit_index >= @capacity_bytes.to_u64 * 8
      word_index = bit_index >> 6
      bit = (bit_index & 63).to_i32
      (@base.as(UInt64*) + word_index).value |= (1_u64 << bit)
    end

    def clear(addr : UInt64) : Nil
      return if @base.null?
      bit_index = addr - @base_addr
      return if bit_index >= @capacity_bytes.to_u64 * 8
      word_index = bit_index >> 6
      bit = (bit_index & 63).to_i32
      (@base.as(UInt64*) + word_index).value &= ~(1_u64 << bit)
    end

    # Zero every bit for addresses in [lo, hi). Hot path: called once per major.
    def reset(lo : UInt64, hi : UInt64) : Nil
      return if @base.null? || hi <= lo
      lo_bit = lo - @base_addr
      hi_bit = hi - @base_addr
      return if lo_bit >= @capacity_bytes.to_u64 * 8
      hi_bit = @capacity_bytes.to_u64 * 8 if hi_bit > @capacity_bytes.to_u64 * 8
      return if hi_bit <= lo_bit

      first_word = lo_bit >> 6
      last_word = (hi_bit - 1) >> 6
      first_bit = (lo_bit & 63).to_i32
      last_bit = ((hi_bit - 1) & 63).to_i32

      base = @base.as(UInt64*)
      if first_word == last_word
        mask = if first_bit == 0 && last_bit == 63
                 ~0_u64
               else
                 lo_mask = ~((1_u64 << first_bit) - 1) if first_bit > 0
                 hi_mask = (1_u64 << (last_bit + 1)) - 1 if last_bit < 63
                 if first_bit == 0
                   hi_mask.not_nil!
                 elsif last_bit == 63
                   lo_mask.not_nil!
                 else
                   lo_mask.not_nil! & hi_mask.not_nil!
                 end
               end
        (base + first_word).value &= ~mask
      else
        # Head partial word
        if first_bit > 0
          (base + first_word).value &= ~(((1_u64 << first_bit) - 1) ^ ~0_u64)
        end
        # Whole words between
        i = first_word + 1
        while i < last_word
          (base + i).value = 0_u64
          i += 1
        end
        # Tail partial word
        if last_bit < 63
          (base + last_word).value &= ~(((1_u64 << (last_bit + 1)) - 1) ^ ~0_u64)
        end
      end
    end

    # Bulk zero of the bitmap (full clear). Used when the heap range is reset
    # wholesale (e.g. on incremental cycle begin). Word-at-a-time clear; the
    # Crystal `memset` builtin is unavailable for opaque pointers, but UInt64
    # stores through the mmap mapping land at full memory bandwidth and the
    # kernel treats untouched pages as already-zero (MADV_DONTNEED-style).
    def zero_all : Nil
      return if @base.null?
      words = (@mapped_bytes >> 3).to_i32
      i = 0_i32
      base = @base.as(UInt64*)
      while i < words
        (base + i).value = 0_u64
        i += 1
      end
      # Trailing bytes (mapped_bytes rounded up to page but we operate in words).
      tail = @mapped_bytes & 7_u64
      if tail > 0
        j = (@base.as(UInt8*)) + (words.to_u64 * 8_u64)
        k = 0_u64
        while k < tail
          (j + k).value = 0_u8
          k += 1
        end
      end
    end

    # Shrink the bitmap mapping to *exactly* cover `needed_bytes` of bitmap
    # (i.e. `needed_bytes * 8` word-aligned heap addresses), rounded up to a
    # power of two (minimum INITIAL_BYTES).  No-op if the mapping is already
    # ≤ `needed_bytes`.
    #
    # Use after the heap range contracts (e.g. after `update_heap_bounds_after_unmap`)
    # to release the surplus bitmap pages back to the OS.
    def shrink_to_fit!(needed_bytes : UInt64) : Nil
      return if @base.null?
      target = needed_bytes
      target = INITIAL_BYTES if target < INITIAL_BYTES
      target = next_power_of_two(target) if target > INITIAL_BYTES
      return if target >= @capacity_bytes
      relocate(@base_addr, target)
    end

    def base_addr : UInt64
      @base_addr
    end

    def base : UInt8*
      @base
    end

    def capacity_bytes : UInt64
      @capacity_bytes
    end

    def covers?(lo : UInt64, hi : UInt64) : Bool
      return false if @base.null?
      lo_bit = lo - @base_addr
      hi_bit = hi - @base_addr
      lo_bit < @capacity_bytes.to_u64 * 8 && hi_bit <= @capacity_bytes.to_u64 * 8
    end

    private def mmap_anonymous(bytes : UInt64) : UInt8*
      ptr = LibC.mmap(
        Pointer(Void).null,
        LibC::SizeT.new(bytes),
        LibC::PROT_READ | LibC::PROT_WRITE,
        LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS,
        -1,
        0
      )
      raise OutOfMemoryError.new("mark bitmap mmap failed") if Gcry.mmap_failed?(ptr)
      ptr.as(UInt8*)
    end

    private def next_power_of_two(v : UInt64) : UInt64
      n = 1_u64
      while n < v
        n <<= 1
      end
      n
    end
  end
end
