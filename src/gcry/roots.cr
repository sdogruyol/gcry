require "c/unistd"
require "c/fcntl"

module Gcry
  # Explicit roots and conservative stack scanning helpers.
  module Roots
    # setjmp is not in Crystal's LibC bindings; we only need it to spill
    # callee-saved registers into a buffer we then scan as roots.
    lib LibSetjmp
      fun setjmp(env : Void*) : Int32
    end

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

    # Combined: spill regs + scan [approx SP, bottom), feeding each candidate
    # to *block*.
    def self.scan_mutator(bottom : Void*, & : Void* ->) : Nil
      spill_registers
      env = uninitialized StaticArray(UInt8, 256)
      LibSetjmp.setjmp(env.to_unsafe.as(Void*))
      scan_range(env.to_unsafe.as(Void*), (env.to_unsafe + env.size).as(Void*)) do |candidate|
        yield candidate
      end
      # Stacks may include a PROT_NONE guard page if SP is stale — probe pages.
      scan_range(stack_pointer, bottom, safe: true) do |candidate|
        yield candidate
      end
      keep_alive(env.to_unsafe.as(Void*))
    end

    # Force the compiler to spill any live pointer held in GP registers onto
    # the stack before a conservative scan (setjmp alone only saves callee-saved).
    def self.spill_registers : Nil
      {% if flag?(:x86_64) %}
        asm("" ::: "rax", "rbx", "rcx", "rdx", "rsi", "rdi",
          "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "memory")
      {% elsif flag?(:aarch64) %}
        asm("" ::: "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
          "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
          "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23",
          "x24", "x25", "x26", "x27", "x28", "memory")
      {% else %}
        env = uninitialized StaticArray(UInt8, 256)
        LibSetjmp.setjmp(env.to_unsafe.as(Void*))
        keep_alive(env.to_unsafe.as(Void*))
      {% end %}
    end

    def self.keep_alive(ptr : Void*) : Nil
      asm("" :: "r"(ptr) : "memory")
    end

    # Conservatively scan [low, high) word-aligned for heap pointers.
    # On x86_64 the stack grows down: pass SP as low, stack_bottom as high.
    #
    # When *safe* is true, each page is probed via write(2)/EFAULT so PROT_NONE
    # fiber guard pages and unmapped holes are skipped (no SIGSEGV). Use for
    # fiber/thread stacks; leave false for /proc/self/maps static ranges.
    MAX_SCAN_BYTES = 64_u64 * 1024 * 1024
    PAGE_SIZE      = 4096_u64

    @@probe_rd = -1
    @@probe_wr = -1

    def self.scan_range(low : Void*, high : Void*, safe : Bool = false, & : Void* ->) : Nil
      return if low.null? || high.null?
      lo = low.address
      hi = high.address
      if lo > hi
        lo, hi = hi, lo
      end

      return if (hi - lo) > MAX_SCAN_BYTES

      word = sizeof(Void*).to_u64
      lo = (lo + word - 1) & ~(word - 1)
      hi &= ~(word - 1)
      return if lo >= hi

      if safe
        scan_range_safe(lo, hi, word) { |c| yield c }
      else
        cursor = Pointer(UInt64).new(lo)
        end_ptr = Pointer(UInt64).new(hi)
        while cursor < end_ptr
          yield Pointer(Void).new(cursor.value)
          cursor += 1
        end
      end
    end

    private def self.scan_range_safe(lo : UInt64, hi : UInt64, word : UInt64, & : Void* ->) : Nil
      ensure_probe_pipe

      page = lo & ~(PAGE_SIZE - 1)
      while page < hi
        page_hi = page + PAGE_SIZE
        page_hi = hi if page_hi > hi

        if page_readable?(page)
          cursor = lo > page ? lo : page
          cursor = (cursor + word - 1) & ~(word - 1)
          while cursor < page_hi
            yield Pointer(Void).new(Pointer(UInt64).new(cursor).value)
            cursor += word
          end
        end

        page += PAGE_SIZE
      end
    end

    private def self.ensure_probe_pipe : Nil
      return if @@probe_wr >= 0
      fds = StaticArray(Int32, 2).new(0)
      return if LibC.pipe(fds) != 0
      @@probe_rd = fds[0]
      @@probe_wr = fds[1]
      flags = LibC.fcntl(@@probe_rd, LibC::F_GETFL)
      LibC.fcntl(@@probe_rd, LibC::F_SETFL, flags | LibC::O_NONBLOCK) if flags >= 0
    end

    # Kernel copies one byte from *page*; EFAULT ⇒ not readable (PROT_NONE / hole).
    private def self.page_readable?(page : UInt64) : Bool
      return false if @@probe_wr < 0
      n = LibC.write(@@probe_wr, Pointer(Void).new(page), 1)
      if n == 1
        buf = uninitialized UInt8
        LibC.read(@@probe_rd, pointerof(buf).as(Void*), 1)
        true
      else
        false
      end
    end
  end
end
