# What does gcry know about the address the process just died on?
#
# The 2026-08-10 soak left one hex number — `Invalid memory access at
# 0x7f1700000149` — and three sessions of argument about what it meant. Every
# fact that would have settled it was in the collector's own tables at the moment
# of the fault: whether the address is inside the heap at all, which chunk and
# size class it lands in, whether the block holding it reads used or free, what
# type_id sits at its start. None of it was asked for, because nothing was
# listening.
#
# `GCRY_SEGV_REPORT=1` listens. On SIGSEGV or SIGBUS it prints what the heap says
# about `si_addr`, then hands the signal back to whoever had it — Crystal's own
# handler, which prints the message and backtrace exactly as before. This adds
# lines; it removes none.
#
# Constraints, and they are strict:
#
#   - No allocation. Everything goes through `RawOut` into a stack buffer.
#   - Report once. A fault *inside* this reporter must not loop; the guard is
#     set before the heap is touched.
#   - Never create the heap. `Gcry.default_heap` would `Heap.new` a missing one,
#     which mmaps inside a signal handler; `default_heap?` returns what exists.
#   - Best effort by construction. The heap may be mid-mutation — that is what a
#     crash usually means — so this reads a few words defensively and says what
#     it saw, rather than pretending to a consistent view.
{% skip_file unless flag?(:unix) %}

module Gcry
  module SegvReport
    @@installed = false
    @@requested = false
    @@reported = false
    @@old_segv = uninitialized LibC::Sigaction
    @@old_bus = uninitialized LibC::Sigaction

    def self.installed? : Bool
      @@installed
    end

    def self.request : Nil
      @@requested = true
    end

    # Installed from the first collection, not from `GC.init`, and that is not a
    # detail: Crystal installs its own SIGSEGV/SIGBUS handler during
    # `init_runtime` with `sigaction(..., nil)`, which discards whatever was
    # there. Installing at init means being overwritten a moment later —
    # measured, the reporter printed nothing at all. From the first collection
    # Crystal's handler is already in place, so it becomes the one this chains
    # back to. The cost is that a fault before the first collection is not
    # explained.
    def self.install_if_requested : Nil
      install if @@requested && !@@installed
    end

    def self.install : Nil
      return if @@installed
      action = uninitialized LibC::Sigaction
      LibC.sigemptyset(pointerof(action.@sa_mask))
      action.sa_flags = LibC::SA_SIGINFO | LibC::SA_ONSTACK
      action.sa_sigaction = ->(sig : Int32, info : LibC::SiginfoT*, ctx : Void*) do
        SegvReport.handle(sig, info, ctx)
      end
      LibC.sigaction(LibC::SIGSEGV, pointerof(action), pointerof(@@old_segv))
      LibC.sigaction(LibC::SIGBUS, pointerof(action), pointerof(@@old_bus))
      @@installed = true
    end

    # Restores the previous handler for `sig` and returns, so the faulting
    # instruction re-executes and dies into it. Calling the old handler directly
    # would mean trusting its flags; this way the kernel dispatches it.
    protected def self.handle(sig : Int32, info : LibC::SiginfoT*, ctx : Void*) : Nil
      unless @@reported
        @@reported = true
        report(sig, info.null? ? Pointer(Void).null : info.value.si_addr, ctx)
      end
      if sig == LibC::SIGBUS
        LibC.sigaction(LibC::SIGBUS, pointerof(@@old_bus), Pointer(LibC::Sigaction).null)
      else
        LibC.sigaction(LibC::SIGSEGV, pointerof(@@old_segv), Pointer(LibC::Sigaction).null)
      end
    end

    # Does any GP register of the faulting context hold the poison? Uses the same
    # ucontext offsets the collector already scans suspended threads with, so
    # there is one description of where registers live rather than two.
    # Returns the poison word a GP register of the faulting context holds, or 0.
    # The word rather than a Bool because the tagged form (`GCRY_POISON_TAG=1`)
    # carries the freed block's address in its low 48 bits, and that is the whole
    # reason to look.
    private def self.context_poison_word(ctx : Void*) : UInt64
      return 0_u64 if ctx.null?
      {% if flag?(:linux) %}
        n = Platform::UCONTEXT_NGREGS
        return 0_u64 if n <= 0
        base = Pointer(UInt64).new(ctx.address + Platform::UCONTEXT_GREGS_OFFSET)
        i = 0
        while i < n
          w = base[i]
          return w if w == Heap::POISON_WORD || (w & Heap::POISON_TAG_MASK) == Heap::POISON_TAG
          i += 1
        end
      {% end %}
      0_u64
    end

    # Untagged poison says a use-after-free happened. Tagged poison
    # (`GCRY_POISON_TAG=1`) says which block's free wrote it, and the block is
    # then described against the heap's own tables exactly as a faulting address
    # would be — so "of what" is answered in the same terms as "where".
    private def self.report_poison_source(word : UInt64) : Nil
      buf = uninitialized UInt8[512]
      len = 0
      # Only decode a block address when this process was actually writing
      # tagged poison. `POISON_WORD >> 48` is `0xDEAD` as well, and a fault on a
      # poisoned pointer *plus an offset* — `0xdeadf2eedeadf2fe`, measured in CI
      # on 2026-08-16 — is neither equal to `POISON_WORD` nor a tagged word, so
      # the tag test alone decoded garbage and reported a block that cannot
      # exist. Ask the heap what it was writing instead of inferring it.
      tagged = (h = Gcry.default_heap?) ? h.poison_tag_addr : false
      if !tagged || word == Heap::POISON_WORD
        len = RawOut.append(buf.to_unsafe, len,
          "gcry: the poison is untagged, so it names no block. GCRY_POISON_TAG=1 writes the freed " \
          "block's address into the poison and this line becomes the block that was freed\n")
        RawOut.flush(buf.to_unsafe, len)
        return
      end

      src = word & Heap::POISON_ADDR_MASK
      len = RawOut.append(buf.to_unsafe, len, "gcry: the free that wrote it was of the block at 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, src)
      heap = Gcry.default_heap?
      unless heap
        len = RawOut.append(buf.to_unsafe, len, " — no gcry heap exists to describe it\n")
        RawOut.flush(buf.to_unsafe, len)
        return
      end
      ptr = Pointer(Void).new(src)
      unless heap.in_heap_span?(ptr)
        len = RawOut.append(buf.to_unsafe, len,
          " — outside the heap span, which should be impossible for an address gcry poisoned\n")
        RawOut.flush(buf.to_unsafe, len)
        return
      end
      info = heap.debug_block_info(ptr)
      unless info[:found]
        len = RawOut.append(buf.to_unsafe, len, " — in no live chunk now; its chunk was released\n")
        RawOut.flush(buf.to_unsafe, len)
        return
      end
      len = RawOut.append(buf.to_unsafe, len, info[:free] ? ", still FREE" : ", since REISSUED")
      len = RawOut.append(buf.to_unsafe, len, ", size ")
      len = RawOut.append_u64(buf.to_unsafe, len, info[:size].to_u64)
      len = RawOut.append(buf.to_unsafe, len, ", flags 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, info[:flags].to_u64)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    private def self.report(sig : Int32, addr : Void*, ctx : Void*) : Nil
      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: ")
      len = RawOut.append(buf.to_unsafe, len, sig == LibC::SIGBUS ? "SIGBUS" : "SIGSEGV")
      len = RawOut.append(buf.to_unsafe, len, " at 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, addr.address)
      len = RawOut.append(buf.to_unsafe, len, " — ")

      a = addr.address

      # The poison first: it forecloses every other reading and needs no heap
      # lookup. Two ways to see it, and the second is the one that fires in
      # practice — `0xdeadf2ee…` is **non-canonical** on x86_64, so dereferencing
      # it raises #GP rather than a page fault and the kernel reports `si_addr`
      # as 0. Measured, not assumed: the first version of this reporter matched
      # on the address and never fired. So when the address cannot say, the
      # registers of the faulting context are asked instead.
      pw = 0_u64
      pw = a if a == Heap::POISON_WORD || (a & Heap::POISON_TAG_MASK) == Heap::POISON_TAG
      pw = context_poison_word(ctx) if pw == 0
      if pw != 0
        len = RawOut.append(buf.to_unsafe, len,
          "gcry's freed-block poison (GCRY_POISON_FREED) is in the faulting context. Something " \
          "followed a pointer read out of a block that had already been freed: a use-after-free, " \
          "not a wild pointer\n")
        RawOut.flush(buf.to_unsafe, len)
        report_poison_source(pw)
        return
      end

      if a == 0
        len = RawOut.append(buf.to_unsafe, len,
          "the kernel reported address 0. On x86_64 that is also what a *non-canonical* " \
          "dereference looks like (#GP carries no address), so this is a null dereference or a " \
          "pointer with garbage in its top bits\n")
        RawOut.flush(buf.to_unsafe, len)
        return
      end

      heap = Gcry.default_heap?
      unless heap
        len = RawOut.append(buf.to_unsafe, len, "no gcry heap exists in this process\n")
        RawOut.flush(buf.to_unsafe, len)
        return
      end

      unless heap.in_heap_span?(addr)
        len = RawOut.append(buf.to_unsafe, len, "outside gcry's heap span [0x")
        len = RawOut.append_hex(buf.to_unsafe, len, heap.heap_span_lo)
        len = RawOut.append(buf.to_unsafe, len, ", 0x")
        len = RawOut.append_hex(buf.to_unsafe, len, heap.heap_span_hi)
        len = RawOut.append(buf.to_unsafe, len,
          ") — never a gcry allocation, so a swept object is not the explanation\n")
        RawOut.flush(buf.to_unsafe, len)
        return
      end

      info = heap.debug_block_info(addr)
      unless info[:found]
        len = RawOut.append(buf.to_unsafe, len,
          "inside the heap span but in no live chunk — the chunk was unmapped, or the address " \
          "is in a hole between chunks\n")
        RawOut.flush(buf.to_unsafe, len)
        return
      end

      len = RawOut.append(buf.to_unsafe, len, info[:free] ? "in a FREE block" : "in a USED block")
      len = RawOut.append(buf.to_unsafe, len, ", size ")
      len = RawOut.append_u64(buf.to_unsafe, len, info[:size].to_u64)
      len = RawOut.append(buf.to_unsafe, len, ", flags 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, info[:flags].to_u64)
      len = RawOut.append(buf.to_unsafe, len, ", first word of the payload 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, info[:first_word])
      len = RawOut.append(buf.to_unsafe, len, ", offset ")
      len = RawOut.append_u64(buf.to_unsafe, len, info[:offset])
      len = RawOut.append(buf.to_unsafe, len, " into it\n")
      RawOut.flush(buf.to_unsafe, len)

      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: ")
      if info[:free]
        len = RawOut.append(buf.to_unsafe, len,
          "a FREE block is the shape of a use-after-free: the collector had given this memory " \
          "back when the fault happened. GCRY_POISON_FREED=1 makes the next one say so without " \
          "this inference")
      else
        len = RawOut.append(buf.to_unsafe, len,
          "a USED block means the memory was live; the fault is a bad offset into it, or the " \
          "block was reissued after being freed while something still pointed at the old object")
      end
      len = RawOut.append(buf.to_unsafe, len, ". collections=")
      len = RawOut.append_u64(buf.to_unsafe, len, heap.collections)
      len = RawOut.append(buf.to_unsafe, len, " heap_size=")
      len = RawOut.append_u64(buf.to_unsafe, len, heap.heap_size)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end
  end
end
