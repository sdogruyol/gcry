# Boehm-style page blacklisting: addresses that appear as false roots are
# recorded so future allocations avoid those pages (reduces false retention).

module Gcry
  class Heap
    BLACKLIST_WORDS = 4096 # 4096 * 64 bits * 4 KiB ≈ 1 GiB address span from heap_min

    property blacklist_enabled : Bool = false
    getter blacklist_hits : UInt64 = 0_u64
    getter blacklist_skips : UInt64 = 0_u64

    @blacklist : UInt64* = Pointer(UInt64).null
    @blacklist_base : UInt64 = 0
    @blacklist_words : Int32 = 0

    protected def ensure_blacklist : Nil
      return unless @blacklist_enabled
      return unless @blacklist.null?

      bytes = (BLACKLIST_WORDS * 8).to_u64
      ptr = LibC.malloc(LibC::SizeT.new(bytes)).as(UInt64*)
      return if ptr.null?
      ptr.as(UInt8*).clear(bytes)
      @blacklist = ptr
      @blacklist_words = BLACKLIST_WORDS
      @blacklist_base = @heap_min == UInt64::MAX ? 0_u64 : (@heap_min & ~4095_u64)
    end

    protected def destroy_blacklist : Nil
      unless @blacklist.null?
        LibC.free(@blacklist.as(Void*))
        @blacklist = Pointer(UInt64).null
      end
      @blacklist_words = 0
      @blacklist_base = 0
      @blacklist_hits = 0
      @blacklist_skips = 0
    end

    # Record a false-positive root candidate address (page granularity).
    def blacklist_address(addr : UInt64) : Nil
      return unless @blacklist_enabled
      ensure_blacklist
      return if @blacklist.null?
      if @blacklist_base == 0 && @heap_min != UInt64::MAX
        @blacklist_base = @heap_min & ~4095_u64
      end
      return if addr < @blacklist_base

      page = (addr - @blacklist_base) // 4096_u64
      return if page >= (@blacklist_words * 64).to_u64

      word = (page >> 6).to_i32
      bit = (page & 63).to_i32
      (@blacklist + word).value |= 1_u64 << bit
      @blacklist_hits += 1
    end

    def blacklisted_page?(addr : UInt64) : Bool
      return false unless @blacklist_enabled
      return false if @blacklist.null? || @blacklist_base == 0
      return false if addr < @blacklist_base

      page = (addr - @blacklist_base) // 4096_u64
      return false if page >= (@blacklist_words * 64).to_u64

      word = (page >> 6).to_i32
      bit = (page & 63).to_i32
      ((@blacklist + word).value & (1_u64 << bit)) != 0
    end

    # Called when type_id_gate rejects an ambient root — classic false hit.
    protected def note_false_root(addr : UInt64) : Nil
      blacklist_address(addr) if @blacklist_enabled
    end

    # Unlink and return the first non-blacklisted freelist node within *limit*
    # steps. Returns null if every candidate in the window is blacklisted
    # (caller may fall back to the head).
    protected def take_non_blacklisted(head : Void*, class_index : Int32, nursery : Bool, limit : Int32 = 64) : Void*
      return Pointer(Void).null if head.null? || !@blacklist_enabled

      user = head
      prev = Pointer(Void).null
      steps = 0
      while !user.null? && steps < limit
        unless blacklisted_page?(user.address)
          nxt = BlockHeader.from_user(user).value.next_free
          if prev.null?
            if nursery
              @nursery_freelists[class_index] = nxt
            else
              @freelists[class_index] = nxt
            end
          else
            ph = BlockHeader.from_user(prev)
            pv = ph.value
            pv.next_free = nxt
            ph.value = pv
          end
          return user
        end
        @blacklist_skips += 1
        prev = user
        user = BlockHeader.from_user(user).value.next_free
        steps += 1
      end
      Pointer(Void).null
    end
  end
end
