module Gcry
  # Explicit roots and conservative stack scanning helpers.
  module Roots
    # Linked list node allocated with libc malloc (immortal w.r.t. gcry heap).
    struct RootNode
      property next : RootNode*
      property pointer : Void*

      def initialize(@pointer : Void*, @next : RootNode* = Pointer(RootNode).null)
      end
    end

    class Set
      getter size : Int32 = 0
      @head : RootNode* = Pointer(RootNode).null

      def finalize
        clear
      end

      def add(pointer : Void*) : Nil
        return if pointer.null?
        node = LibC.malloc(sizeof(RootNode)).as(RootNode*)
        raise OutOfMemoryError.new("root node malloc failed") if node.null?
        node.value = RootNode.new(pointer, @head)
        @head = node
        @size += 1
      end

      def delete(pointer : Void*) : Bool
        return false if pointer.null?
        prev = Pointer(RootNode).null
        node = @head
        while node
          if node.value.pointer == pointer
            if prev.null?
              @head = node.value.next
            else
              n = prev.value
              n.next = node.value.next
              prev.value = n
            end
            LibC.free(node.as(Void*))
            @size -= 1
            return true
          end
          prev = node
          node = node.value.next
        end
        false
      end

      def clear : Nil
        node = @head
        while node
          nxt = node.value.next
          LibC.free(node.as(Void*))
          node = nxt
        end
        @head = Pointer(RootNode).null
        @size = 0
      end

      def each(& : Void* ->) : Nil
        node = @head
        while node
          yield node.value.pointer
          node = node.value.next
        end
      end
    end

    # Approximate current stack pointer (address of a local).
    def self.stack_pointer : Void*
      local = 0
      pointerof(local).as(Void*)
    end

    # Conservatively scan [low, high) word-aligned for heap pointers.
    # On x86_64 the stack grows down: pass SP as low, stack_bottom as high.
    #
    # Refuses absurd ranges (e.g. fiber SP vs stale main-stack bottom) that
    # would walk unmapped gaps and SIGSEGV.
    MAX_SCAN_BYTES = 16_u64 * 1024 * 1024

    def self.scan_range(low : Void*, high : Void*, & : Void* ->) : Nil
      return if low.null? || high.null?
      lo = low.address
      hi = high.address
      if lo > hi
        lo, hi = hi, lo
      end

      return if (hi - lo) > MAX_SCAN_BYTES

      # Align to pointer size.
      word = sizeof(Void*).to_u64
      lo = (lo + word - 1) & ~(word - 1)
      hi &= ~(word - 1)

      cursor = Pointer(UInt64).new(lo)
      end_ptr = Pointer(UInt64).new(hi)
      while cursor < end_ptr
        yield Pointer(Void).new(cursor.value)
        cursor += 1
      end
    end
  end
end
