# Where in this process does the dying block's address live?
#
# The elimination chain is complete and it ends in a contradiction. When the
# `Deque(Fiber::Stack)` buffer is swept, its address is:
#
#   - not in any used heap block (`mark_audit_all_parents`, 0 reports),
#   - not in any suspended thread's captured GP registers (0 hits),
#   - never offered to the mark by the mutator-stack scan (0 offers),
#   - not in the explicit root set (0),
#
# and yet moments later the SIGSEGV report finds it on a *running fiber's*
# stack. Every place gcry looks says the value is not there, and the crash says
# it is. One of those two claims is wrong, and no further narrowing of where
# gcry looks can settle it — the next question has to be asked from outside the
# collector's own idea of where roots live.
#
# So ask the kernel. At the moment of death, walk every readable mapping in
# `/proc/self/maps` and search it, word-aligned, for that address. Then name the
# region that holds it. There are only a few kinds of answer and each one is a
# different defect:
#
#   - **a fiber stack, below the scan window** — the value was live on a stack
#     gcry scanned only part of. Root coverage, and the window is the bug.
#   - **a fiber stack, inside the scan window** — the scan walked those bytes
#     and did not offer the value. The scan is dropping it: a filter bug.
#   - **a gcry heap block** — the all-parents audit is lying, or the holder is
#     a *free* block whose payload is still live (a resurrected freelist entry).
#   - **TLS / thread-control blocks** — anonymous pages next to a thread stack
#     that gcry never scans at all. A whole missing root source.
#   - **nowhere** — the value genuinely does not exist at the moment of the
#     sweep and is reconstructed afterwards. That would move the hunt to the
#     mutator: something re-derives the pointer from a stale copy.
#
# `GCRY_ADDRESS_SPACE_AUDIT=1`, and it implies `GCRY_DYING_REGISTER_AUDIT=1`
# because it is that audit's unreferenced branch that triggers it. Off by
# default and violently expensive — it reads the whole resident address space
# inside the pause — so it fires **once per collection**, for the first dying
# block that survives every other check, and stops after
# `ADDRESS_SPACE_SCAN_LIMIT` bytes.
#
# Interior hits are counted but not reported one by one: a word pointing into
# the middle of the buffer is how `Deque` iteration works and would bury the
# base hits, which are the ones that name a holder.

module Gcry
  class Heap
    # `GCRY_ADDRESS_SPACE_AUDIT=1`. See src/gcry/address_space_audit.cr.
    property address_space_audit : Bool = false

    getter address_space_audits : UInt64 = 0_u64
    getter address_space_hits : UInt64 = 0_u64
    # Audits that walked the whole space and found the value in no region.
    getter address_space_absent : UInt64 = 0_u64

    # Stop after this much. A process with a gigabyte resident would otherwise
    # hold the world stopped for the length of a gigabyte memcmp.
    ADDRESS_SPACE_SCAN_LIMIT = 512_u64 * 1024 * 1024

    # Base hits reported per audit. The first few name the holder; the rest are
    # the same finding printed again inside a stopped world.
    ADDRESS_SPACE_REPORT_LIMIT = 6

    # `pread` block size. Small enough to sit on a fiber stack, large enough
    # that the syscall count is not the cost of the walk.
    ADDRESS_SPACE_READ_BLOCK = 8192

    # One audit per collection: the walk is O(resident memory). `MAX` rather
    # than 0 so the very first collection is not mistaken for one already
    # audited.
    @address_space_audited_at = UInt64::MAX

    # A second slot, so the two questions do not compete for one. The dying
    # audit's block is whatever died first in a collection; the dying-type
    # audit's is the one that was asked for by name
    # (src/gcry/thread_block_audit.cr), and one arm must not be able to spend
    # the other's budget.
    @address_space_type_audited_at = UInt64::MAX

    protected def audit_address_space_once(target : UInt64, size : UInt64) : Nil
      return unless @address_space_audit
      return if @address_space_audited_at == @collections
      @address_space_audited_at = @collections
      audit_address_space(target, size, "dying block")
    end

    protected def audit_address_space_for_type(target : UInt64, size : UInt64) : Nil
      return unless @address_space_audit
      return if @address_space_type_audited_at == @collections
      @address_space_type_audited_at = @collections
      audit_address_space(target, size, "dying watched-type block")
    end

    private def audit_address_space(target : UInt64, size : UInt64, why : String) : Nil
      @address_space_audits &+= 1
      regions = 0_u64
      scanned = 0_u64
      skipped = 0_u64
      # A walk that stopped early has to say how much it never looked at, or
      # "not found anywhere else" is a claim about the limit and not about the
      # address space.
      unscanned_regions = 0_u64
      unscanned_bytes = 0_u64
      base_hits = 0_u64
      interior_hits = 0_u64
      reported = 0
      @collector_frame_hits = 0_u64
      truncated = false
      high = target &+ size

      unreadable = 0_u64

      # Read the address space through `/proc/self/mem` rather than dereferencing
      # it. A mapping `/proc/self/maps` calls readable can still fault on access
      # — the first run of this audit took a SIGBUS at 0x…567000 and killed the
      # very collection it was measuring. `pread` on that file reports the same
      # page as an error instead, so the audit degrades to "could not read one
      # page" where it used to take the process down.
      mem_fd = LibC.open("/proc/self/mem".to_unsafe.as(LibC::Char*), 0)

      walked = false
      if mem_fd >= 0
        begin
          walked = Platform.each_map_region do |lo, hi, perms, name, name_len|
            if scanned >= ADDRESS_SPACE_SCAN_LIMIT
              truncated = true
              unscanned_regions &+= 1
              unscanned_bytes &+= (hi - lo)
            elsif skip_region?(perms, name, name_len)
              skipped &+= 1
            else
              regions &+= 1
              scanned &+= (hi - lo)
              reported = scan_region_for_target(mem_fd, lo, hi, target, high,
                pointerof(base_hits), pointerof(interior_hits), pointerof(unreadable),
                reported, perms, name, name_len)
            end
          end
        ensure
          LibC.close(mem_fd)
        end
      end

      @address_space_hits &+= base_hits
      @address_space_absent &+= 1 if walked && base_hits == 0

      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: address-space audit (")
      len = RawOut.append(buf.to_unsafe, len, why)
      len = RawOut.append(buf.to_unsafe, len, ") — 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, target)
      if !walked
        len = RawOut.append(buf.to_unsafe, len, " not searched: /proc/self/maps could not be read")
      else
        len = RawOut.append(buf.to_unsafe, len, " base hits ")
        len = RawOut.append_u64(buf.to_unsafe, len, base_hits)
        len = RawOut.append(buf.to_unsafe, len, ", interior hits ")
        len = RawOut.append_u64(buf.to_unsafe, len, interior_hits)
        len = RawOut.append(buf.to_unsafe, len, ", across ")
        len = RawOut.append_u64(buf.to_unsafe, len, regions)
        len = RawOut.append(buf.to_unsafe, len, " regions / ")
        len = RawOut.append_u64(buf.to_unsafe, len, scanned >> 20)
        len = RawOut.append(buf.to_unsafe, len, " MiB (")
        len = RawOut.append_u64(buf.to_unsafe, len, skipped)
        len = RawOut.append(buf.to_unsafe, len, " skipped, ")
        len = RawOut.append_u64(buf.to_unsafe, len, unreadable)
        len = RawOut.append(buf.to_unsafe, len, " unreadable pages), compared against ")
        len = RawOut.append_u64(buf.to_unsafe, len, @classifier_fibers)
        len = RawOut.append(buf.to_unsafe, len, " fibers / ")
        len = RawOut.append_u64(buf.to_unsafe, len, @classifier_pooled_stacks)
        len = RawOut.append(buf.to_unsafe, len, " pooled stacks / ")
        len = RawOut.append_u64(buf.to_unsafe, len, @classifier_thread_bounds)
        len = RawOut.append(buf.to_unsafe, len, " thread bounds")
        if truncated
          len = RawOut.append(buf.to_unsafe, len, ", TRUNCATED at the scan limit: ")
          len = RawOut.append_u64(buf.to_unsafe, len, unscanned_regions)
          len = RawOut.append(buf.to_unsafe, len, " regions / ")
          len = RawOut.append_u64(buf.to_unsafe, len, unscanned_bytes >> 20)
          len = RawOut.append(buf.to_unsafe, len, " MiB never searched")
        end
      end
      len = RawOut.append(buf.to_unsafe, len, ". collection ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # Copy a region out through `/proc/self/mem` and search the copy. On a read
    # error the block is retried a page at a time, so one bad page costs one
    # page rather than the whole region. Returns the updated report count.
    private def scan_region_for_target(fd : Int32, lo : UInt64, hi : UInt64,
                                       target : UInt64, high : UInt64,
                                       base : UInt64*, interior : UInt64*, unreadable : UInt64*,
                                       reported : Int32,
                                       perms : UInt8*, name : UInt8*, name_len : Int32) : Int32
      buf = uninitialized UInt8[ADDRESS_SPACE_READ_BLOCK]
      dst = buf.to_unsafe.as(Void*)
      off = lo
      while off < hi
        want = hi - off
        want = ADDRESS_SPACE_READ_BLOCK.to_u64 if want > ADDRESS_SPACE_READ_BLOCK
        n = LibC.pread(fd, dst, LibC::SizeT.new(want), off.to_i64!)
        if n > 0
          reported = scan_words_for_target(buf.to_unsafe, n.to_i32, off, target, high,
            base, interior, reported, lo, hi, perms, name, name_len)
        else
          page = Roots::PAGE_SIZE.to_u64
          p = off
          stop = off + want
          while p < stop
            m = LibC.pread(fd, dst, LibC::SizeT.new(page), p.to_i64!)
            if m > 0
              reported = scan_words_for_target(buf.to_unsafe, m.to_i32, p, target, high,
                base, interior, reported, lo, hi, perms, name, name_len)
            else
              unreadable.value &+= 1
            end
            p += page
          end
        end
        off += want
      end
      reported
    end

    private def scan_words_for_target(buf : UInt8*, len : Int32, at : UInt64,
                                      target : UInt64, high : UInt64,
                                      base : UInt64*, interior : UInt64*, reported : Int32,
                                      lo : UInt64, hi : UInt64,
                                      perms : UInt8*, name : UInt8*, name_len : Int32) : Int32
      words = buf.as(UInt64*)
      count = len // 8
      i = 0
      while i < count
        value = words[i]
        if value == target
          base.value &+= 1
          hit_at = at &+ (i.to_u64 &* 8)
          # The collector's own call chain is explicitly *not evidence* — the
          # audit carries the target through it as an argument — and it was
          # spending the whole report budget: 245 of the 276 holder lines in
          # the acikturkiye run were that, and only the four leftover slots
          # said anything about where the value really lives. Count them,
          # print one, and leave the budget to holders that could be evidence.
          if collector_own_frame?(hit_at)
            @collector_frame_hits &+= 1
            if @collector_frame_hits == 1
              report_address_space_hit(target, hit_at, lo, hi, perms, name, name_len)
            end
          elsif reported < ADDRESS_SPACE_REPORT_LIMIT
            reported += 1
            report_address_space_hit(target, hit_at, lo, hi, perms, name, name_len)
          end
        elsif value > target && value < high
          interior.value &+= 1
        end
        i += 1
      end
      reported
    end

    # Regions the audit must not read, or must not bother reading.
    private def skip_region?(perms : UInt8*, name : UInt8*, name_len : Int32) : Bool
      return true unless perms[0] == 'r'.ord.to_u8
      # `[vvar]` and `[vsyscall]` are kernel pages: reading them either faults
      # or means something. `/dev/` mappings can have side effects on read.
      return true if region_named?(name, name_len, "[vvar]")
      return true if region_named?(name, name_len, "[vsyscall]")
      return true if region_named?(name, name_len, "[vdso]")
      return true if region_prefixed?(name, name_len, "/dev/")
      false
    end

    private def report_address_space_hit(target : UInt64, at : UInt64, lo : UInt64, hi : UInt64,
                                         perms : UInt8*, name : UInt8*, name_len : Int32) : Nil
      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry:   0x")
      len = RawOut.append_hex(buf.to_unsafe, len, target)
      len = RawOut.append(buf.to_unsafe, len, " held at 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, at)
      len = RawOut.append(buf.to_unsafe, len, " in [0x")
      len = RawOut.append_hex(buf.to_unsafe, len, lo)
      len = RawOut.append(buf.to_unsafe, len, ",0x")
      len = RawOut.append_hex(buf.to_unsafe, len, hi)
      len = RawOut.append(buf.to_unsafe, len, ") ")
      len = RawOut.append_bytes(buf.to_unsafe, len, perms, 4)
      len = RawOut.append(buf.to_unsafe, len, " ")
      if name_len > 0
        len = RawOut.append_bytes(buf.to_unsafe, len, name, name_len)
      else
        len = RawOut.append(buf.to_unsafe, len, "anon")
      end
      len = RawOut.append(buf.to_unsafe, len, " — ")
      len = describe_holder(buf.to_unsafe, len, at, lo, hi)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # What gcry thinks that address is. The maps name says `anon` for a fiber
    # stack, a TLS block and a large object alike; only the collector can tell
    # them apart, and which one it is *is* the finding.
    private def describe_holder(buf : UInt8*, len : Int32, at : UInt64,
                                region_lo : UInt64, region_hi : UInt64) : Int32
      # Per hit, so the summary's coverage numbers belong to the last
      # classification rather than to a sum of six of them.
      @classifier_fibers = 0_u64
      @classifier_pooled_stacks = 0_u64
      @classifier_thread_bounds = 0_u64

      if holder = find_block(Pointer(Void).new(at))
        len = RawOut.append(buf, len, "gcry heap block 0x")
        len = RawOut.append_hex(buf, len, BlockHeader.user_from(holder).address)
        len = RawOut.append(buf, len, BlockHeader.free?(holder) ? " (FREE" : " (used")
        len = RawOut.append(buf, len, heap_marked?(holder) ? ", marked" : ", unmarked")
        # Size, ATOMIC and the payload's first Int32, because "a marked heap
        # block holds it" is not yet an answer. The mark audit skips ATOMIC
        # parents exactly as `scan_object` does, so a marked ATOMIC holder is a
        # *different* defect from a marked scanned one: it means something
        # stored a heap pointer in an allocation Crystal declared pointer-free,
        # and no walk will ever follow it.
        len = RawOut.append(buf, len, ", ")
        len = RawOut.append_u64(buf, len, holder.value.size.to_u64)
        len = RawOut.append(buf, len, BlockHeader.atomic?(holder) ? " bytes, ATOMIC" : " bytes, scanned")
        if holder.value.size >= 4
          len = RawOut.append(buf, len, ", first Int32 ")
          len = RawOut.append_u64(buf, len,
            BlockHeader.user_from(holder).as(UInt32*).value.to_u64)
        end
        len = RawOut.append(buf, len, ")")
        return len
      end

      # The current stack first, and against the window the scan *actually*
      # used rather than a recomputed one. Everything below that window was
      # written after the scan — by the mark, by the sweep, by this audit's own
      # frames, which hold the target as an argument — and reading those as
      # "held on a running fiber's stack" would be the instrument reporting
      # itself.
      if described = describe_mutator_stack_holder(buf, len, at)
        return described
      end

      if described = describe_fiber_stack_holder(buf, len, at)
        return described
      end

      # A stack sitting in a `Fiber::StackPool` belongs to no fiber, so the
      # fiber walk above cannot see it — and neither can the root scan. It still
      # holds the frames of whatever fiber released it, which is exactly how a
      # dead pointer survives a collection and comes back alive when the pool
      # hands the stack to the next fiber.
      if described = describe_pooled_stack_holder(buf, len, at)
        return described
      end

      if described = describe_thread_stack_holder(buf, len, at)
        return described
      end

      # Nothing owns it. The shape of the region is then the only evidence left,
      # and one shape is decisive: a `Fiber::StackPool` stack is
      # `STACK_SIZE` with its lowest page mprotected away, so the mapping that
      # remains is exactly `STACK_SIZE - PAGE_SIZE` starting one page above a
      # `STACK_SIZE` boundary. A region of that shape owned by neither a fiber
      # nor a pool is a stack **in flight** — checked out of the pool and not
      # yet attached to a fiber, or released by a dead fiber and not yet back —
      # and in that window it is scanned by nothing.
      if fiber_stack_geometry?(region_lo, region_hi)
        l = RawOut.append(buf, len, "IN-FLIGHT fiber stack (")
        l = RawOut.append_u64(buf, l, (region_hi - region_lo) >> 10)
        l = RawOut.append(buf, l, " KiB mapped, guard below, owned by no fiber and in no pool), ")
        l = RawOut.append_u64(buf, l, region_hi - at)
        l = RawOut.append(buf, l, " bytes below the stack top")
        return l
      end

      # Nothing owns it and it is not a pool stack's exact geometry. The shape
      # is still evidence: a large anonymous mapping whose hit sits just below
      # its top is what a *thread* stack looks like — mapped whole, used from
      # the high end down — and the first four catches of the dying-`Thread`
      # arm all landed in one, at byte-identical offsets below the top. Stated
      # with its criteria so it reads as a shape and not as a verdict; the
      # thread-population line beside the report says whose it can be.
      below_top = region_hi > at ? region_hi - at : 0_u64
      span = region_hi > region_lo ? region_hi - region_lo : 0_u64
      l = RawOut.append(buf, len, "no gcry block, no fiber stack, no pooled stack, no thread stack — ")
      l = RawOut.append_u64(buf, l, span >> 10)
      l = RawOut.append(buf, l, " KiB anonymous mapping, hit ")
      l = RawOut.append_u64(buf, l, below_top)
      l = RawOut.append(buf, l, " bytes below its top")
      if span >= (1_u64 << 20) && below_top <= (64_u64 << 10)
        l = RawOut.append(buf, l, " — mapped whole and used from the high end: the shape of a thread stack")
      end
      l
    end

    private def fiber_stack_geometry?(lo : UInt64, hi : UInt64) : Bool
      {% if @top_level.has_constant?("Fiber") && Fiber.has_constant?("StackPool") %}
        size = Fiber::StackPool::STACK_SIZE.to_u64
        page = Roots::PAGE_SIZE.to_u64
        return false unless hi > lo
        # Size only. An earlier version also required the guard page to sit on a
        # `STACK_SIZE` boundary and missed six hits in one run: `allocate_stack`
        # mmaps, and mmap promises page alignment, not stack-size alignment.
        (hi - lo) == size - page
      {% else %}
        false
      {% end %}
    end

    # Same test `describe_mutator_stack_holder` applies, asked before the
    # report budget is charged rather than after.
    private def collector_own_frame?(at : UInt64) : Bool
      stack = Fiber.current.@stack
      lo = stack.pointer.address
      hi = stack.bottom.address
      return false unless lo < hi && at >= lo && at < hi
      entry = @collect_entry_sp
      entry > 0 && at < entry
    end

    private def describe_mutator_stack_holder(buf : UInt8*, len : Int32, at : UInt64) : Int32?
      stack = Fiber.current.@stack
      lo = stack.pointer.address
      hi = stack.bottom.address
      return nil unless lo < hi && at >= lo && at < hi

      # The collector's own frames first, and for the same reason
      # `GCRY_BIRTH_GRACE`'s holder search excludes them (src/gcry/birth_grace.cr):
      # this audit carries the target as an argument through a call chain that
      # sits *below* where the collector was entered — and the scan window's low
      # bound is deeper still, so those frames are **inside** the window the scan
      # used. Without this branch the instrument reports itself as "the scan
      # walked these bytes and did not offer the value", which is a filter bug
      # that does not exist. Measured on the gate: 5 of 6 base hits in the `dies`
      # arm are the audit's own chain, and the 6th is its caller's `addr` local.
      entry = @collect_entry_sp
      if entry > 0 && at < entry
        l = RawOut.append(buf, len, "the collecting fiber's own stack, ")
        l = RawOut.append_u64(buf, l, entry - at)
        l = RawOut.append(buf, l, " bytes below where the collector was entered (0x")
        l = RawOut.append_hex(buf, l, entry)
        l = RawOut.append(buf, l, ") — the collector's own call chain, this audit's included. Not evidence")
        return l
      end

      scan_lo = Roots.last_mutator_low
      scan_hi = Roots.last_mutator_high
      if scan_lo < scan_hi && at >= scan_lo && at < scan_hi
        l = RawOut.append(buf, len, "the collecting fiber's own stack, INSIDE the window the scan used [0x")
        l = RawOut.append_hex(buf, l, scan_lo)
        l = RawOut.append(buf, l, ",0x")
        l = RawOut.append_hex(buf, l, scan_hi)
        l = RawOut.append(buf, l, ")")
        return l
      end

      l = RawOut.append(buf, len, "the collecting fiber's own stack, below the scanned window — a frame written after the scan (the collector's, or this audit's own)")
      l
    end

    private def describe_fiber_stack_holder(buf : UInt8*, len : Int32, at : UInt64) : Int32?
      stw_multi = @world_stopped && multi_mutator_threads?
      out = nil
      Fiber.unsafe_each do |fiber|
        next if out
        @classifier_fibers &+= 1
        stack = fiber.@stack
        guard = stack.pointer.address + Roots::PAGE_SIZE
        bottom = stack.bottom.address
        next unless guard < bottom
        next unless at >= guard && at < bottom

        top = fiber_stack_scan_top(fiber, guard, stw_multi)
        l = RawOut.append(buf, len, fiber.running? ? "running" : "parked")
        l = RawOut.append(buf, l, " fiber stack, ")
        l = if at < top
              RawOut.append(buf, l, "BELOW the scan window (scan starts at 0x")
            else
              RawOut.append(buf, l, "inside the scan window (starts at 0x")
            end
        l = RawOut.append_hex(buf, l, top)
        l = RawOut.append(buf, l, ", bottom 0x")
        l = RawOut.append_hex(buf, l, bottom)
        l = RawOut.append(buf, l, ")")
        out = l
      end
      out
    end

    # Walks every execution context's stack pool. The deque is read through its
    # raw ivars rather than `each`, and clamped: the whole reason this audit
    # exists is a deque whose buffer is about to be freed, and iterating that
    # with the normal API inside the pause is how an instrument becomes the
    # second crash.
    # What the classifier had to compare against, last audit. A "no pooled
    # stack" answer from a walk that found zero pools is not an answer.
    getter classifier_fibers : UInt64 = 0_u64
    getter classifier_pooled_stacks : UInt64 = 0_u64
    getter classifier_thread_bounds : UInt64 = 0_u64

    # Hits that landed in the collector's own call chain, which the audit
    # carries the target through. Reported once and otherwise counted, so the
    # report budget is spent on holders that could be evidence.
    getter collector_frame_hits : UInt64 = 0_u64

    private def describe_pooled_stack_holder(buf : UInt8*, len : Int32, at : UInt64) : Int32?
      out = nil
      {% if Thread.instance_vars.any? { |v| v.name == "execution_context" } %}
        Fiber::ExecutionContext.unsafe_each do |ec|
          next if out
          pool = ec.stack_pool?
          next unless pool
          deque = pool.@deque
          buffer = deque.@buffer
          next if buffer.null?
          capacity = deque.@capacity
          size = deque.@size
          next if capacity <= 0 || size <= 0 || size > capacity
          start = deque.@start
          next if start < 0 || start >= capacity
          i = 0
          while i < size
            stack = buffer[(start + i) % capacity]
            i += 1
            @classifier_pooled_stacks &+= 1
            lo = stack.pointer.address
            hi = stack.bottom.address
            next unless lo < hi && at >= lo && at < hi
            l = RawOut.append(buf, len, "POOLED fiber stack [0x")
            l = RawOut.append_hex(buf, l, lo)
            l = RawOut.append(buf, l, ",0x")
            l = RawOut.append_hex(buf, l, hi)
            l = RawOut.append(buf, l, "), owned by no fiber and scanned by nothing, ")
            l = RawOut.append_u64(buf, l, hi - at)
            l = RawOut.append(buf, l, " bytes below the stack top")
            out = l
            break
          end
        end
      {% end %}
      out
    end

    # Thread stacks come from the pre-stop snapshot: `pthread_getattr_np` is not
    # callable with the world stopped.
    private def describe_thread_stack_holder(buf : UInt8*, len : Int32, at : UInt64) : Int32?
      out = nil
      Thread.unsafe_each do |thread|
        next if out
        bounds = Platform.snapshotted_stack_bounds(thread.to_unsafe)
        next unless bounds
        @classifier_thread_bounds &+= 1
        lo = bounds[0].address
        hi = bounds[1].address
        next unless lo < hi && at >= lo && at < hi
        l = RawOut.append(buf, len, "thread stack [0x")
        l = RawOut.append_hex(buf, l, lo)
        l = RawOut.append(buf, l, ",0x")
        l = RawOut.append_hex(buf, l, hi)
        l = RawOut.append(buf, l, ")")
        out = l
      end
      out
    end

    private def region_named?(name : UInt8*, name_len : Int32, label : String) : Bool
      return false unless name_len == label.bytesize
      region_prefixed?(name, name_len, label)
    end

    private def region_prefixed?(name : UInt8*, name_len : Int32, prefix : String) : Bool
      n = prefix.bytesize
      return false if name_len < n
      src = prefix.to_unsafe
      i = 0
      while i < n
        return false if name[i] != src[i]
        i += 1
      end
      true
    end
  end
end
