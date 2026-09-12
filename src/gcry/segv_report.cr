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

    # How to read a fault outside the heap span. Pure and public so the choice
    # can be gated without faking a signal: the branch that matters fires only
    # while `pthread_getattr_np` is in flight, which a harness cannot enter.
    #
    # `descriptor_field` is the shape the `Thread` use-after-free takes — the
    # fault lands a small fixed offset past the `pthread_t` being queried
    # (glibc's `struct pthread` at +0x418 in every sighting), so the address is
    # a field of a descriptor and not a wild pointer.
    enum OutOfSpan
      NoQuery
      DescriptorField
      QueryFar
    end

    OUT_OF_SPAN_FIELD_MAX = 64_u64 << 10

    def self.out_of_span_reading(fault : UInt64, in_flight : UInt64) : OutOfSpan
      return OutOfSpan::NoQuery if in_flight == 0
      return OutOfSpan::QueryFar unless fault > in_flight
      (fault - in_flight) < OUT_OF_SPAN_FIELD_MAX ? OutOfSpan::DescriptorField : OutOfSpan::QueryFar
    end

    # Frame-walk bounds. 64 frames is more than any Crystal call chain worth
    # printing, and 1 MiB above the faulting SP is more than any live frame
    # can be: past either, the chain being followed is not a chain.
    FRAME_WALK_MAX  = 64
    FRAME_WALK_SPAN = 1_u64 << 20
    # The conservative fallback's window and cap. 4 KiB above the faulting sp
    # covers the frames that matter; 24 addresses is a readable chain.
    SP_SCAN_SPAN = 4096_u64
    SP_SCAN_MAX  =       24

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
        # After the description of the address, and outside `report`: that has
        # several early returns and the writer is worth having on every one.
        report_writer_frames(ctx)
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
    # Linux only. Darwin's `ucontext_t` keeps its registers in a different
    # layout (`__mcontext`) and gcry has no reader for it, so on Darwin a crash
    # on a poisoned pointer arrives with `si_addr == 0` and nothing to identify
    # it — observed on Darwin CI, 2026-08-17, where the report could only offer
    # "a null dereference". The `si_addr == 0` branch now says that limitation
    # out loud instead of implying a diagnosis it cannot make.
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
      heap = Gcry.default_heap?
      # A poison word *plus an offset* still carries `0xDEAD` in its top bits,
      # so the tag test alone accepts it and decodes an address that is not the
      # freed block. Measured on 2026-08-17: a fault at `poison + 0x418` — glibc
      # reading `struct pthread` through a poisoned `pthread_t` — decoded a
      # block five slots along, reported it as `REISSUED, size 192`, and its
      # cleared flags then produced a false "freed by an explicit free". The
      # poison fills a payload with one repeated word, so a genuine one always
      # names a block **base**; anything else is the poison with arithmetic done
      # to it, and names nothing.
      if heap && (info = heap.debug_block_info(Pointer(Void).new(src)))[:found] && info[:offset] != 0
        # An offset was added to the poison before it faulted. The poison names
        # a block *base*, so the base is recoverable: the containing block's
        # user address is `src - offset`, and that is the block the free wrote
        # — provided the added offset stayed inside it, which is exactly the
        # case where `debug_block_info` reports a non-zero offset into a block
        # that begins at the poisoned address. Say so, with the condition
        # attached, instead of giving up: a Darwin catch on 2026-08-17 landed
        # 760 bytes in and the report could otherwise name nothing, because the
        # register reader that would carry the clean word is Linux-only.
        base = src - info[:offset]
        len = RawOut.append(buf.to_unsafe, len,
          "gcry: the poison in the fault has an offset added to it — it lands ")
        len = RawOut.append_u64(buf.to_unsafe, len, info[:offset])
        len = RawOut.append(buf.to_unsafe, len, " bytes into the block at 0x")
        len = RawOut.append_hex(buf.to_unsafe, len, base)
        len = RawOut.append(buf.to_unsafe, len,
          ", so the free that wrote it was of that block, unless the offset was larger than the " \
          "block and landed in a later one\n")
        RawOut.flush(buf.to_unsafe, len)
        # Describe the recovered base in the same terms as any other block,
        # rather than stopping at "it names no block".
        report_poison_block(heap, base)
        return
      end
      len = RawOut.append(buf.to_unsafe, len, "gcry: the free that wrote it was of the block at 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, src)
      unless heap
        len = RawOut.append(buf.to_unsafe, len, " — no gcry heap exists to describe it\n")
        RawOut.flush(buf.to_unsafe, len)
        return
      end
      RawOut.flush(buf.to_unsafe, len)
      report_poison_block(heap, src)
    end

    # Describes the block a poison names, in the same terms wherever the address
    # came from — decoded directly, or recovered from a poison that had an
    # offset added to it.
    private def self.report_poison_block(heap : Heap, src : UInt64) : Nil
      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: that block, 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, src)
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
      # Which path gave the block back. "The collector decided it was garbage"
      # and "the program asked for it to be freed" are different defects with
      # different owners, and the 2026-08-16 hunt spent a round unable to tell
      # them apart from the poison alone.
      #
      # Only while the block is **still free**. `SWEPT` is set beside `FREE` by
      # the sweep's freelist link and cleared when the block is handed out
      # again, so on a reissued block the bit describes the reissue and not the
      # free that wrote the poison — and reading it anyway has now produced a
      # false "explicit free" three times: twice from a misdecoded address in
      # the 2026-08-16 hunt, and once on 2026-08-20 against a block the
      # dying-type audit had watched the **sweep** condemn one collection
      # earlier (`bench/log/linux/2026-08-20-dying-thread-holder/`). A verdict
      # that contradicts a direct observation of the death is worse than no
      # verdict.
      #
      # And only where the bit can exist at all. `SWEPT` is written by
      # `push_size_class_free`, the header-freelist reclaim; under
      # `bitmap_alloc` the sweep is `sweep_small_bitmap`, which reclaims by
      # `occ &= mark` and writes no header — that is the point of the
      # representation — and on the headerless layout there is no header to
      # write. Reading the bit there returns 0 for every block the sweep
      # condemned, so the old two-way branch reported "freed by an explicit
      # free" about every swept block on those heaps. Same reasoning as the
      # reissue case above: a verdict that is wrong is worse than none.
      len = if info[:free]
              if heap.bitmap_alloc?
                RawOut.append(buf.to_unsafe, len,
                  " — which path freed it cannot be recorded under the bitmap allocator: the sweep writes no header")
              elsif (info[:flags] & BlockHeader::Flags::SWEPT) != 0
                RawOut.append(buf.to_unsafe, len,
                  " — freed by the SWEEP, so the collector decided it was garbage")
              else
                RawOut.append(buf.to_unsafe, len,
                  " — freed by an explicit free, not by the sweep")
              end
            else
              RawOut.append(buf.to_unsafe, len,
                " — which path freed it cannot be read from these flags: they describe the reissue, not the free")
            end
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)

      # Naming the block is where this stopped being able to help. `GCRY_POISON_HOLDERS=1`
      # goes one step further and asks *who still points at it* — the root set,
      # the live heap, the fiber stacks. See src/gcry/poison_holders.cr.
      PoisonHolders.search(heap, src, info[:size].to_u64) if PoisonHolders.requested?
    end

    # The frame that produced the address, and the call chain above it.
    #
    # Every sighting of the open live-large-object release has named *what* was
    # written and never *who* wrote it, because the only backtrace available
    # was Crystal's: `Exception::CallStack` allocates its DWARF tables — on a
    # fat binary, hundreds of kilobytes — and needs `Fiber.current`, neither of
    # which exists in a signal handler on a heap that is already broken.
    # Measured, it produced `Failed to raise an exception: END_OF_STACK` and
    # `Thread#current_fiber cannot be nil`, and its allocation *changed the
    # crash*: the DWARF buffer became the released block, which cost two
    # rounds of misattribution
    # (`bench/log/linux/2026-09-12-thread-churn-large-uaf/FINDINGS.md`).
    #
    # So this walks the frame records itself, from the faulting context, with
    # no allocation and no locks. The frame record is the same shape on both
    # architectures gcry supports — `[fp]` is the caller's fp and `[fp + 8]`
    # its return address, x86_64 by the SysV prologue and aarch64 by AAPCS —
    # so one loop covers both.
    #
    # Addresses are printed as `exe+offset` against the load bias, which is
    # the only form that survives a PIE: the runtime address differs every
    # run, and `addr2line -e <binary> <offset>` wants the link-time one. The
    # report ends with that command already assembled.
    private def self.report_writer_frames(ctx : Void*) : Nil
      {% if flag?(:linux) && (flag?(:x86_64) || flag?(:aarch64)) %}
        return if ctx.null?
        pc = Pointer(UInt64).new(ctx.address &+ Platform::UCONTEXT_PC_OFFSET).value
        sp = Pointer(UInt64).new(ctx.address &+ Platform::UCONTEXT_SP_OFFSET).value
        fp = Pointer(UInt64).new(ctx.address &+ Platform::UCONTEXT_FP_OFFSET).value
        bias = Platform.exe_bias
        return if pc == 0

        buf = uninitialized UInt8[1024]
        len = 0
        len = RawOut.append(buf.to_unsafe, len, "gcry: writer — the faulting instruction is at 0x")
        len = RawOut.append_hex(buf.to_unsafe, len, pc)
        if bias != 0 && Platform.exe_text?(pc)
          len = RawOut.append(buf.to_unsafe, len, " = exe+0x")
          len = RawOut.append_hex(buf.to_unsafe, len, pc &- bias)
        else
          len = RawOut.append(buf.to_unsafe, len, ", outside the executable's own text — a libc or kernel frame")
        end
        len = RawOut.append(buf.to_unsafe, len, ". sp 0x")
        len = RawOut.append_hex(buf.to_unsafe, len, sp)
        len = RawOut.append(buf.to_unsafe, len, " fp 0x")
        len = RawOut.append_hex(buf.to_unsafe, len, fp)
        {% if flag?(:x86_64) %}
          # `gregs[REG_CR2]`, the hardware faulting address. Printed beside
          # `si_addr` and not instead of it: the two disagreeing is itself the
          # answer, and they did — a fault inside the collector reported
          # `si_addr == 0` while CR2 named the address the instruction actually
          # touched.
          len = RawOut.append(buf.to_unsafe, len, " cr2 0x")
          len = RawOut.append_hex(buf.to_unsafe, len,
            Pointer(UInt64).new(ctx.address &+ Platform::UCONTEXT_GREGS_OFFSET &+ 22 * 8).value)
        {% end %}
        len = RawOut.append(buf.to_unsafe, len, "\n")
        RawOut.flush(buf.to_unsafe, len)

        # `addr2line` takes the offsets, so they go on one line in the order it
        # wants them. The faulting pc first: it is the frame that did the write.
        len = 0
        len = RawOut.append(buf.to_unsafe, len, "gcry: writer — addr2line -f -C -e <binary>")
        emitted = 0
        if bias != 0 && Platform.exe_text?(pc)
          len = RawOut.append(buf.to_unsafe, len, " 0x")
          len = RawOut.append_hex(buf.to_unsafe, len, pc &- bias)
          emitted += 1
        end
        {% if flag?(:aarch64) %}
          # A leaf store faulting has made no frame record, so its caller is
          # only in x30. On x86_64 the return address is on the stack and the
          # walk below finds it.
          lr = Pointer(UInt64).new(ctx.address &+ Platform::UCONTEXT_LR_OFFSET).value
          if bias != 0 && Platform.exe_text?(lr)
            len = RawOut.append(buf.to_unsafe, len, " 0x")
            len = RawOut.append_hex(buf.to_unsafe, len, lr &- bias)
            emitted += 1
          end
        {% end %}

        # Bounded on every axis a broken frame chain can run away on: a frame
        # count, a monotonic fp, and a window above the faulting sp. A corrupt
        # `[fp]` that points back down or far away ends the walk rather than
        # looping on it.
        frames = 0
        limit = sp &+ FRAME_WALK_SPAN
        while frames < FRAME_WALK_MAX && fp >= sp && fp < limit && (fp & 7) == 0
          break unless Roots.page_readable?(fp & ~(Roots::PAGE_SIZE &- 1))
          ret = Pointer(UInt64).new(fp &+ 8).value
          nxt = Pointer(UInt64).new(fp).value
          if bias != 0 && Platform.exe_text?(ret) && len < 900
            len = RawOut.append(buf.to_unsafe, len, " 0x")
            len = RawOut.append_hex(buf.to_unsafe, len, ret &- bias)
            emitted += 1
          end
          break unless nxt > fp
          fp = nxt
          frames += 1
        end

        len = RawOut.append(buf.to_unsafe, len, "\n")
        RawOut.flush(buf.to_unsafe, len)

        # The frame chain is a bonus, not the mechanism. Crystal builds without
        # `--release` keep locals `%rsp`-relative and omit the frame pointer for
        # small functions, so `[fp]` is a caller's frame at best and garbage at
        # worst — measured, the chain above emitted the faulting pc and nothing
        # else on the very fault this exists for.
        #
        # What always works is what the collector already does to find roots:
        # read the words above the stack pointer and keep the ones that land in
        # this binary's text. Those are the return addresses, mixed with
        # whatever else looks like one. Noise is the right trade — a call chain
        # with three extra entries names the writer, and an empty report does
        # not.
        len = 0
        len = RawOut.append(buf.to_unsafe, len,
          "gcry: writer — return addresses above sp: addr2line -f -C -e <binary>")
        seen = 0
        cursor = sp & ~7_u64
        stop = cursor &+ SP_SCAN_SPAN
        while cursor < stop && seen < SP_SCAN_MAX && len < 940
          break if (cursor & (Roots::PAGE_SIZE &- 1)) == 0 && !Roots.page_readable?(cursor)
          w = Pointer(UInt64).new(cursor).value
          if bias != 0 && Platform.exe_text?(w)
            len = RawOut.append(buf.to_unsafe, len, " 0x")
            len = RawOut.append_hex(buf.to_unsafe, len, w &- bias)
            seen += 1
          end
          cursor &+= 8
        end
        if seen == 0 && emitted == 0
          len = 0
          len = RawOut.append(buf.to_unsafe, len,
            "gcry: writer — nothing above the faulting sp is in this binary's text, so the " \
            "write came from libc or from a stack this walk cannot see\n")
        else
          len = RawOut.append(buf.to_unsafe, len, "\n")
        end
        RawOut.flush(buf.to_unsafe, len)
      {% end %}
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

      # Before anything else about the address: was the collector inside
      # `pthread_getattr_np` when it faulted? That call has SEGV'd twice on
      # aarch64 CI and both times left a libc frame and one hex number. The id
      # is non-zero only while the snapshot is querying that thread, so a
      # non-zero read here names the thread the fault is about.
      if (in_flight = Platform.stack_bounds_in_flight) != 0
        ilen = 0
        ibuf = uninitialized UInt8[512]
        ilen = RawOut.append(ibuf.to_unsafe, ilen,
          "gcry: the collector was inside the pthread stack-bounds query for thread 0x")
        ilen = RawOut.append_hex(ibuf.to_unsafe, ilen, in_flight)
        ilen = RawOut.append(ibuf.to_unsafe, ilen,
          " — the fault is in that query, not in the heap. Visited/read so far: ")
        ilen = RawOut.append_u64(ibuf.to_unsafe, ilen, Platform.stack_bounds_visited)
        ilen = RawOut.append(ibuf.to_unsafe, ilen, "/")
        ilen = RawOut.append_u64(ibuf.to_unsafe, ilen, Platform.stack_bounds_read)
        ilen = RawOut.append(ibuf.to_unsafe, ilen, "\n")
        RawOut.flush(ibuf.to_unsafe, ilen)

        # The one bit that separates the two readings left standing: had this
        # thread ever been queried successfully? A repeat means it stopped being
        # queryable between two snapshots; a first-timer means it never was.
        ilen = 0
        ilen = RawOut.append(ibuf.to_unsafe, ilen, "gcry: that thread had ")
        if Platform.stack_bounds_seen_before?(in_flight)
          ilen = RawOut.append(ibuf.to_unsafe, ilen,
            "been read successfully before — it stopped being queryable between two snapshots\n")
        elsif Platform.stack_bounds_seen_full?
          ilen = RawOut.append(ibuf.to_unsafe, ilen,
            "no recorded earlier read, but the id table is full, so this is not evidence\n")
        else
          ilen = RawOut.append(ibuf.to_unsafe, ilen,
            "never been read successfully — the first query for it is the one that faulted\n")
        end
        RawOut.flush(ibuf.to_unsafe, ilen)
      end

      # The poison first: it forecloses every other reading and needs no heap
      # lookup. Two ways to see it, and the second is the one that fires in
      # practice — `0xdeadf2ee…` is **non-canonical** on x86_64, so dereferencing
      # it raises #GP rather than a page fault and the kernel reports `si_addr`
      # as 0. Measured, not assumed: the first version of this reporter matched
      # on the address and never fired. So when the address cannot say, the
      # registers of the faulting context are asked instead.
      # Registers first, address second. `si_addr` can be the poison *plus an
      # offset* — a poisoned pointer that libc indexed before dereferencing —
      # while a register usually still holds the word as it was read. Taking the
      # address first decoded the offset value and named the wrong block.
      pw = context_poison_word(ctx)
      if pw == 0 && (a == Heap::POISON_WORD || (a & Heap::POISON_TAG_MASK) == Heap::POISON_TAG)
        pw = a
      end
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
        len = RawOut.append(buf.to_unsafe, len, "the kernel reported address 0. ")
        {% if flag?(:x86_64) %}
          len = RawOut.append(buf.to_unsafe, len,
            "On x86_64 that is also what a *non-canonical* dereference looks like (#GP carries no " \
            "address), so this is a null dereference or a pointer with garbage in its top bits")
        {% else %}
          len = RawOut.append(buf.to_unsafe, len,
            "A poisoned pointer can read as 0 here too, so this is a null dereference or a pointer " \
            "with garbage in its top bits")
        {% end %}
        {% unless flag?(:linux) %}
          len = RawOut.append(buf.to_unsafe, len,
            " — and gcry cannot tell which on this platform: the check that looks for the poison " \
            "in the faulting context's registers is implemented for Linux only")
        {% end %}
        len = RawOut.append(buf.to_unsafe, len, "\n")
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
        # "Never a gcry allocation" is true of the *address*; "so a swept object
        # is not the explanation" does not follow when the collector is inside
        # the pthread stack-bounds query. There the address is a field of the
        # descriptor some `pthread_t` points at, and that id was read out of a
        # `Thread` object — one gcry may have reclaimed and reissued, in which
        # case it no longer holds poison and reads as an ordinary value. Three
        # control runs on 2026-08-20 printed exactly this line while faulting at
        # the in-flight id + 0x418, i.e. the known use-after-free, and the line
        # excluded the mechanism by name
        # (`bench/log/linux/2026-08-20-dying-thread-holder/FINDINGS.md`).
        inf = Platform.stack_bounds_in_flight
        case out_of_span_reading(addr.address, inf)
        in .descriptor_field?
          len = RawOut.append(buf.to_unsafe, len, ") — never a gcry allocation itself, but it is ")
          len = RawOut.append_u64(buf.to_unsafe, len, addr.address - inf)
          len = RawOut.append(buf.to_unsafe, len,
            " bytes past the in-flight thread id above: libc reading a field of the descriptor that " \
            "id points at. The id came from a `Thread`'s @system_handle, and a `Thread` whose block " \
            "was reclaimed and then reissued carries no poison — so a swept object is NOT excluded " \
            "here, it is the leading reading\n")
        in .query_far?
          len = RawOut.append(buf.to_unsafe, len,
            ") — never a gcry allocation. The collector is inside the stack-bounds query, so this is " \
            "a read through a `pthread_t` that came out of a `Thread` object; a swept object is not " \
            "excluded\n")
        in .no_query?
          len = RawOut.append(buf.to_unsafe, len,
            ") — never a gcry allocation, so a swept object is not the explanation\n")
        end
        RawOut.flush(buf.to_unsafe, len)
        return
      end

      info = heap.debug_block_info(addr)
      unless info[:found]
        # `GCRY_UNMAP_GUARD=1` keeps a released chunk mapped as `PROT_NONE`
        # rather than unmapping it, precisely so this branch can say more than
        # "it is gone": which chunk, how big, which release path let it go, and
        # at which collection.
        #
        # `GCRY_RELEASE_LEDGER=1` keeps the same record and unmaps anyway. That
        # buys the identity back for faults the guard cannot be present for —
        # anything that needs the range to be reused — at the cost of certainty
        # about what is there *now*, which is why the two say different things
        # below.
        if g = heap.guarded_release_at(a)
          base, glen, kind, gen, tag, occ = g
          len = RawOut.append(buf.to_unsafe, len,
            heap.unmap_guard? ? "in a chunk gcry RELEASED — base 0x" : "in a range gcry RELEASED and unmapped — base 0x")
          len = RawOut.append_hex(buf.to_unsafe, len, base)
          len = RawOut.append(buf.to_unsafe, len, ", ")
          len = RawOut.append_u64(buf.to_unsafe, len, glen)
          len = RawOut.append(buf.to_unsafe, len, " bytes, ")
          len = RawOut.append(buf.to_unsafe, len,
            kind == Heap::GUARD_KIND_LARGE ? "large-object release" : "empty size-class chunk release")
          len = RawOut.append(buf.to_unsafe, len, ", at collection ")
          len = RawOut.append_u64(buf.to_unsafe, len, gen)
          len = RawOut.append(buf.to_unsafe, len, "; the write is ")
          len = RawOut.append_u64(buf.to_unsafe, len, a - base)
          len = RawOut.append(buf.to_unsafe, len, " bytes into it. Collections since: ")
          # Zero or one is a race inside the release window; many means the
          # mutator has been carrying a pointer into released memory for a long
          # time, which is a different defect with a different fix.
          len = RawOut.append_u64(buf.to_unsafe, len, heap.collections - gen)
          # Captured while the block was still mapped. For a Crystal reference
          # the low 32 bits are the type_id, which is what turns "a 75 KiB
          # something" into a name.
          if tag != 0
            len = RawOut.append(buf.to_unsafe, len, ". First user word at release: 0x")
            len = RawOut.append_hex(buf.to_unsafe, len, tag)
            len = RawOut.append(buf.to_unsafe, len, " (type_id ")
            len = RawOut.append_u64(buf.to_unsafe, len, tag & 0xffff_ffff_u64)
            len = RawOut.append(buf.to_unsafe, len, ")")
          end
          # The question the record could not answer until 2026-09-12, and the
          # one that splits the open "live large object released under load"
          # item in half: was the chunk released while blocks in it were still
          # allocated — an accounting bug in the release decision — or were
          # they genuinely free, making this a stale pointer a mutator kept?
          # Read from the occupancy bitmap at the moment of release, before
          # the `mprotect`.
          if occ >= 0
            len = RawOut.append(buf.to_unsafe, len, ". Blocks still allocated at release: ")
            len = RawOut.append_u64(buf.to_unsafe, len, occ.to_u64)
          end
          # Under the ledger the mapping was handed back to the kernel, so
          # whatever answers at this address now may belong to something else
          # entirely. Saying otherwise would borrow the guard's certainty.
          len = RawOut.append(buf.to_unsafe, len,
            heap.unmap_guard? ? "\n" : ". The range was unmapped, so this address may since have " \
                                       "been remapped by something else\n")
          RawOut.flush(buf.to_unsafe, len)
          # Same question the poison path asks, asked of a released range: the
          # ledger says *what* was let go and when, never who was still holding
          # it. Under `GCRY_UNMAP_GUARD=1` this is the sharpest form of the
          # question — the range is still mapped, so nothing has been reissued
          # over the evidence.
          PoisonHolders.search(heap, base, glen) if PoisonHolders.requested?
          return
        end
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
