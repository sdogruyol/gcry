require "./platform/os"

module Gcry
  {% if flag?(:darwin) %}
    module Platform
      # The fd-free readability probe (`Roots.page_readable?`).
      lib LibMachVM
        fun mach_vm_read_overwrite(target_task : UInt32, address : UInt64, size : UInt64,
                                   data : UInt64, outsize : UInt64*) : Int32
      end
    end
  {% end %}

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

    # Approximate current stack pointer (address of a local). Fine for
    # conservative *scan* (may start slightly above true SP). Unsafe as the
    # high bound for *clearing* — that must use `#hardware_stack_pointer`.
    def self.stack_pointer : Void*
      local = 0
      pointerof(local).as(Void*)
    end

    # True SP via the architecture register. Used by stack scrub so we never
    # zero the current leaf frame (pointerof(local) sits mid-frame).
    def self.hardware_stack_pointer : Void*
      {% if flag?(:x86_64) %}
        sp = uninitialized UInt64
        asm("movq %rsp, $0" : "=r"(sp) :: "volatile")
        Pointer(Void).new(sp)
      {% elsif flag?(:aarch64) %}
        sp = uninitialized UInt64
        asm("mov $0, sp" : "=r"(sp) :: "volatile")
        Pointer(Void).new(sp)
      {% else %}
        stack_pointer
      {% end %}
    end

    {% if flag?(:win32) %}
      REGISTER_BUFFER_SIZE = 1248
    {% else %}
      REGISTER_BUFFER_SIZE = 256
    {% end %}

    # Combined: spill regs + scan [SP−red_zone, bottom), feeding each candidate
    # to *block*. *stack_low* is the low end of the stack *bottom* belongs to
    # (`Fiber::Stack#pointer`): the window is scanned whole however deep it is
    # when it lies inside that stack (`scan_stack`).
    def self.scan_mutator(bottom : Void*, stack_low : Void*, & : Void* ->) : Nil
      spill_registers
      env = uninitialized StaticArray(UInt8, REGISTER_BUFFER_SIZE)
      capture_registers(env.to_unsafe)
      scan_range(env.to_unsafe.as(Void*), (env.to_unsafe + env.size).as(Void*)) do |candidate|
        yield candidate
      end
      # Prefer hardware SP (− red zone). pointerof(local) sits mid-frame and
      # skipped the leaf / red-zone window — Parallel collect-on-alloc then
      # missed caller-held buffers (Kemal EC>1).
      red = {% if flag?(:aarch64) && flag?(:win32) %} 16_u64 {% elsif flag?(:x86_64) && !flag?(:win32) %} 128_u64 {% else %} 0_u64 {% end %}
      sp = hardware_stack_pointer.address
      low = sp > red ? sp - red : 0_u64
      # Also cover pointerof(local) if it somehow sits below hardware SP
      # (shouldn't) — take the lesser address so we never shrink the window.
      approx = stack_pointer.address
      low = approx if approx < low
      # Recorded, not re-derived: `GCRY_BIRTH_GRACE` asks whether a stack slot
      # was inside the window this scan actually used, and computing a second
      # opinion of "where SP was" from another frame would answer a different
      # question. Two stores on a once-per-collection path.
      @@last_mutator_low = low
      @@last_mutator_high = bottom.address
      scan_stack(low, bottom.address, stack_low.address, bottom.address) do |candidate|
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
      {% elsif flag?(:aarch64) && flag?(:win32) %}
        # X18 is the Windows thread-environment pointer, not a scratch register.
        asm("" ::: "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
                   "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
                   "x16", "x17", "x19", "x20", "x21", "x22", "x23",
                   "x24", "x25", "x26", "x27", "x28", "memory")
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

    # Spill + scan the setjmp buffer only (no full stack). Used by exclusive
    # precise-stack mode so register-held roots survive without word-scanning
    # the mutator stack.
    def self.each_spilled_register(& : Void* ->) : Nil
      spill_registers
      env = uninitialized StaticArray(UInt8, REGISTER_BUFFER_SIZE)
      capture_registers(env.to_unsafe)
      scan_range(env.to_unsafe.as(Void*), (env.to_unsafe + env.size).as(Void*)) do |candidate|
        yield candidate
      end
      keep_alive(env.to_unsafe.as(Void*))
    end

    # Shared with the collect-entry diagnostics: Windows GNU does not export
    # the POSIX setjmp symbol. Callers provide REGISTER_BUFFER_SIZE bytes.
    #
    # `setjmp` alone does not expose every callee-saved register. x86_64 glibc
    # PTR_MANGLEs rbp (with rsp and the return address: XOR with a TLS guard,
    # then a rotate), and Crystal keeps no frame pointer on Linux
    # (`--frame-pointers auto`), so rbp is an ordinary register LLVM may hold a
    # pointer in. Whether some frame between that holder and here saved rbp to
    # the scanned stack is the compiler's choice. The collector's own chain
    # happens to on 1.21.0, but a small caller does not: a value inline asm
    # placed in rbp was in neither the buffer nor any frame above the capture,
    # debug and `--release` alike
    # (`process_spec/regression/15_callee_saved_register_root_spec.cr`).
    # So the frame-pointer register is stored as it is, into the last word of
    # the buffer, past anything a `setjmp` writes (glibc aarch64 reaches 216
    # bytes when it saves GCSPR; x86_64 glibc 80, Darwin 192). aarch64 gets
    # the same for x29, which glibc stores plain today but Darwin's libplatform
    # munges along with lr and sp. Windows `RtlCaptureContext` stores Rbp/Fp
    # unmangled. rbx, r12-r15 and x19-x28 are stored plain by every `setjmp`.
    @[AlwaysInline]
    def self.capture_registers(buffer : UInt8*) : Nil
      {% if flag?(:win32) %}
        buffer.clear(1248)
        LibC.RtlCaptureContext(buffer.align_up(16).as(LibC::CONTEXT*))
      {% else %}
        LibSetjmp.setjmp(buffer.as(Void*))
        {% if flag?(:x86_64) || flag?(:aarch64) %}
          fp = uninitialized UInt64
          {% if flag?(:x86_64) %}
            asm("movq %rbp, $0" : "=r"(fp) :: "volatile")
          {% else %}
            asm("mov $0, x29" : "=r"(fp) :: "volatile")
          {% end %}
          # Word-aligned so `scan_range`, which aligns inward, reads it.
          slot = (buffer.address &+ (REGISTER_BUFFER_SIZE - 8)) & ~7_u64
          Pointer(UInt64).new(slot).value = fp
        {% end %}
      {% end %}
    end

    def self.keep_alive(ptr : Void*) : Nil
      asm("" :: "r"(ptr) : "memory")
    end

    # Conservatively scan [low, high) word-aligned for heap pointers.
    # On x86_64 the stack grows down: pass SP as low, stack_bottom as high.
    #
    # When *safe* is true, each page is probed (`page_readable?`) so PROT_NONE
    # fiber guard pages and unmapped holes are skipped (no SIGSEGV). Use for
    # fiber/thread stacks; leave false for /proc/self/maps static ranges.
    MAX_SCAN_BYTES = 64_u64 * 1024 * 1024
    # The unit of the readability probes, and the length Crystal passes to
    # `mprotect` for a fiber stack's guard. It is not the kernel's page size,
    # and nothing that has to be in that unit uses it: `madvise` alignment is
    # `Platform.host_page_size` (`sysconf`), and the pagemap index and a guard's
    # real extent are `runtime_page_size`. A probe answers for the page its
    # address lies in, so probing in 4 KiB steps is right on a 16 or 64 KiB
    # kernel too, only more often.
    #
    # Until 2026-09-29 the pagemap low-water probe and the guard offsets used
    # this constant, and `GC.init` warned about it on every non-4 KiB kernel —
    # including every Apple Silicon Mac, where both were already asked of the
    # OS and the warning was wrong (`bench/log/linux/2026-09-29-page-size-units/`).
    PAGE_SIZE = 4096_u64

    # The kernel's page size, from `sysconf` on first use. Where a guard's real
    # extent matters this is the unit: a 4 KiB `mprotect` on a 16 KiB-page
    # kernel protects the whole 16 KiB page. `uninitialized`, read as 0 until
    # set: an initializer would be a Crystal `once`, and `GC.init` runs before
    # there is a fiber to run it on. Filling it is idempotent, so a race between
    # two first readers writes the same value twice.
    @@runtime_page_size = uninitialized UInt64

    def self.runtime_page_size : UInt64
      v = @@runtime_page_size
      return v unless v == 0
      {% if flag?(:unix) %}
        actual = LibC.sysconf(LibC::SC_PAGESIZE)
        if actual > 0
          @@runtime_page_size = actual.to_u64
          return actual.to_u64
        end
      {% end %}
      PAGE_SIZE
    end

    # The readability probe (`page_readable?`). A pipe when one could be made,
    # else the fd-free probe; `ensure_probe_pipe` decides once, at `GC.init`.
    @@probe_rd = -1
    @@probe_wr = -1
    @@probe_fd_free = false

    # Ranges `scan_range` refused for being longer than `MAX_SCAN_BYTES`.
    #
    # The refusal is a sanity valve against nonsense bounds. For anything that
    # is really a root range it is a dropped root, and until 2026-08-22 it was
    # also invisible: a BSS larger than 64 MiB was skipped whole with nothing
    # said, which is the same defect the adjacency cap in `linux_roots.cr`
    # carried at 1 MiB. Until 2026-10-10 a stack was the same: see
    # `scan_stack`. Callers that can have a legitimately large range use
    # `scan_range_chunked` or `scan_stack`; this counter exists so that
    # anything still hitting the valve says so.
    @@oversize_skips = 0_u64

    def self.oversize_skips : UInt64
      @@oversize_skips
    end

    # The window the last `scan_mutator` word-scanned. See the note there.
    class_getter last_mutator_low : UInt64 = 0_u64
    class_getter last_mutator_high : UInt64 = 0_u64

    {% if flag?(:gcry_hl_assert) %}
      # Address of the word most recently yielded by a scan loop (diagnostics).
      class_property hl_slot : UInt64 = 0_u64
    {% end %}

    def self.scan_range(low : Void*, high : Void*, safe : Bool = false, & : Void* ->) : Nil
      return if low.null? || high.null?
      lo = low.address
      hi = high.address
      if lo > hi
        lo, hi = hi, lo
      end

      if (hi - lo) > MAX_SCAN_BYTES
        @@oversize_skips &+= 1
        return
      end

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
          {% if flag?(:gcry_hl_assert) %} @@hl_slot = cursor.address {% end %}
          yield Pointer(Void).new(cursor.value)
          cursor += 1
        end
      end
    end

    # `scan_range` for a range that is allowed to be arbitrarily long.
    #
    # Static ranges are the case: a program's BSS is as big as the program says
    # it is, and refusing it drops every global root in it. Split on word-
    # aligned `MAX_SCAN_BYTES` boundaries so the valve in `scan_range` is never
    # reached and no word is lost at a seam.
    def self.scan_range_chunked(low : Void*, high : Void*, safe : Bool = false, & : Void* ->) : Nil
      return if low.null? || high.null?
      lo = low.address
      hi = high.address
      if lo > hi
        lo, hi = hi, lo
      end
      word = sizeof(Void*).to_u64
      lo = (lo + word - 1) & ~(word - 1)
      hi &= ~(word - 1)
      return if lo >= hi

      while lo < hi
        stop = hi - lo > MAX_SCAN_BYTES ? lo + MAX_SCAN_BYTES : hi
        scan_range(Pointer(Void).new(lo), Pointer(Void).new(stop), safe: safe) { |c| yield c }
        lo = stop
      end
    end

    # `scan_range` for a stack window [low, high), cut from the stack
    # [stack_low, stack_high) — a fiber's `Fiber::Stack` or the pthread bounds
    # glibc reported. Inside that stack the window is scanned however long it
    # is; a window that is not inside the stack it names is the nonsense
    # `MAX_SCAN_BYTES` exists for, and keeps the valve.
    #
    # A stack is as deep as the program recursed. Until 2026-10-10 every stack
    # went through the valve, and under `ulimit -s unlimited` a main thread
    # recursing past 64 MiB lost its whole stack from the root set: a block
    # held only by main's frame was swept at depth 20 000 with 2.4 KiB frames,
    # `oversize_skips` 1
    # (`process_spec/regression/54_deep_stack_roots_spec.cr`).
    #
    # Chunked from the bottom (*high*) down, and with *safe* a chunk whose top
    # page does not read ends the scan. A stack is mapped in one piece from its
    # bottom to the deepest page it has used — guards sit at the low end, and
    # the main thread's is one grows-down mapping — so the first unreadable
    # page below a chunk is where the stack ends. That is the cap on a long
    # window: what is mapped, not what was reserved. The main thread's bounds
    # under an unlimited RLIMIT_STACK are glibc's gap to the next mapping,
    # terabytes, and a window clamped to that low end would otherwise be
    # probed page by page. The first chunk is `scan_range` exactly as before,
    # so a window under 64 MiB is scanned as it always was.
    def self.scan_stack(low : UInt64, high : UInt64, stack_low : UInt64, stack_high : UInt64, safe : Bool = true, & : Void* ->) : Nil
      lo, hi = low < high ? {low, high} : {high, low}
      inside = stack_low < stack_high && stack_low <= lo && hi <= stack_high
      if !inside && hi - lo > MAX_SCAN_BYTES
        @@oversize_skips &+= 1
        return
      end
      word = sizeof(Void*).to_u64
      lo = (lo + word - 1) & ~(word - 1)
      hi &= ~(word - 1)
      first = true
      while lo < hi
        break if safe && !first && !page_readable?((hi - 1) & ~(PAGE_SIZE - 1))
        start = hi - lo > MAX_SCAN_BYTES ? hi - MAX_SCAN_BYTES : lo
        scan_range(Pointer(Void).new(start), Pointer(Void).new(hi), safe: safe) { |c| yield c }
        hi = start
        first = false
      end
    end

    # Fiber/pthread stacks usually have a leading PROT_NONE guard then a
    # contiguous readable body. Fast path: skip leading holes, confirm the last
    # page, bulk-scan. Slow path: walk readable runs if the end is unmapped
    # (glibc sometimes reports a range that includes a trailing guard).
    private def self.scan_range_safe(lo : UInt64, hi : UInt64, word : UInt64, & : Void* ->) : Nil
      {% if flag?(:win32) %}
        Platform.each_readable_region(lo, hi) do |run_lo, run_hi|
          start = (run_lo + word - 1) & ~(word - 1)
          finish = run_hi & ~(word - 1)
          cursor = Pointer(UInt64).new(start)
          end_ptr = Pointer(UInt64).new(finish)
          while cursor < end_ptr
            {% if flag?(:gcry_hl_assert) %} @@hl_slot = cursor.address {% end %}
            yield Pointer(Void).new(cursor.value)
            cursor += 1
          end
        end
      {% else %}
      ensure_probe_pipe

      page = lo & ~(PAGE_SIZE - 1)
      while page < hi && !page_readable?(page)
        page += PAGE_SIZE
      end
      return if page >= hi

      last_page = (hi - 1) & ~(PAGE_SIZE - 1)
      if last_page == page || page_readable?(last_page)
        start = lo > page ? lo : page
        start = (start + word - 1) & ~(word - 1)
        finish = hi & ~(word - 1)
        return if start >= finish

        cursor = Pointer(UInt64).new(start)
        end_ptr = Pointer(UInt64).new(finish)
        while cursor < end_ptr
          {% if flag?(:gcry_hl_assert) %} @@hl_slot = cursor.address {% end %}
          yield Pointer(Void).new(cursor.value)
          cursor += 1
        end
        return
      end

      # End not readable — scan contiguous readable runs only.
      while page < hi
        while page < hi && !page_readable?(page)
          page += PAGE_SIZE
        end
        break if page >= hi

        run_lo = page
        while page < hi && page_readable?(page)
          page += PAGE_SIZE
        end
        run_hi = page
        run_hi = hi if run_hi > hi

        start = lo > run_lo ? lo : run_lo
        start = (start + word - 1) & ~(word - 1)
        finish = (run_hi < hi ? run_hi : hi) & ~(word - 1)
        next if start >= finish

        cursor = Pointer(UInt64).new(start)
        end_ptr = Pointer(UInt64).new(finish)
        while cursor < end_ptr
          {% if flag?(:gcry_hl_assert) %} @@hl_slot = cursor.address {% end %}
          yield Pointer(Void).new(cursor.value)
          cursor += 1
        end
      end
      {% end %}
    end

    # Makes the readability probe, once. `GC.init` calls it first thing, while
    # the process still has fds to spare; the platform layer and the safe
    # scans call it again, which is then a load and a branch.
    #
    # Until 2026-10-10 the pipe was made by the first collection's first safe
    # scan, and a `pipe()` that failed there — EMFILE, ENFILE — left
    # `page_readable?` answering false for every page: the collection skipped
    # its own stack, every other stack, the static ranges and every
    # `GC_add_roots` range. RLIMIT_NOFILE 64 and a full table, then
    # `GC.collect`: SIGSEGV
    # (`process_spec/regression/55_probe_pipe_fd_pressure_spec.cr`). So the
    # pipe is made at init, and where it cannot be the probe goes without an
    # fd; with neither there is no safe scan at all, and init says so and
    # stops rather than run a collector that drops roots.
    #
    # Close-on-exec: the pipe used to go into every child `Process.run`
    # started, as fds 9 and 10. Not close-on-fork: a forked child inherits
    # the pair and shares it with the parent, which still answers right —
    # each prober writes its byte before it reads one, so a read never finds
    # the pipe empty, whose byte it takes does not matter.
    def self.ensure_probe_pipe : Nil
      {% if flag?(:win32) %}
        @@probe_wr = 0
      {% else %}
        return if @@probe_wr >= 0 || @@probe_fd_free
        fds = StaticArray(Int32, 2).new(-1)
        {% if flag?(:darwin) %}
          made = LibC.pipe(fds) == 0
          if made
            LibC.fcntl(fds[0], LibC::F_SETFD, LibC::FD_CLOEXEC)
            LibC.fcntl(fds[1], LibC::F_SETFD, LibC::FD_CLOEXEC)
          end
        {% else %}
          made = LibC.pipe2(fds, LibC::O_CLOEXEC) == 0
        {% end %}
        if made
          flags = LibC.fcntl(fds[0], LibC::F_GETFL)
          LibC.fcntl(fds[0], LibC::F_SETFL, flags | LibC::O_NONBLOCK) if flags >= 0
          @@probe_rd = fds[0]
          @@probe_wr = fds[1]
          return
        end
        pipe_errno = Errno.value.value
        # A stack local is readable and page 0 is not: a probe that does not
        # tell those two apart (ENOSYS, a seccomp EPERM) is no probe.
        local = 0_u8
        if fd_free_readable?(pointerof(local).address) && !fd_free_readable?(0_u64)
          @@probe_fd_free = true
          return
        end
        no_probe(pipe_errno, Errno.value.value)
      {% end %}
    end

    {% unless flag?(:win32) %}
      private def self.no_probe(pipe_errno : Int32, fd_free_errno : Int32) : NoReturn
        buf = uninitialized UInt8[RawOut::LIMIT]
        len = RawOut.append(buf.to_unsafe, 0, "gcry: cannot probe page readability: pipe() failed (errno ")
        len = RawOut.append_u64(buf.to_unsafe, len, pipe_errno.to_u64)
        {% if flag?(:darwin) %}
          len = RawOut.append(buf.to_unsafe, len, ") and mach_vm_read_overwrite was refused")
        {% elsif flag?(:linux) %}
          len = RawOut.append(buf.to_unsafe, len, ") and process_vm_readv was refused (errno ")
          len = RawOut.append_u64(buf.to_unsafe, len, fd_free_errno.to_u64)
          len = RawOut.append(buf.to_unsafe, len, ")")
        {% else %}
          len = RawOut.append(buf.to_unsafe, len, ") and this platform has no fd-free probe")
        {% end %}
        len = RawOut.append(buf.to_unsafe, len, "; every stack and static root scan needs one\n")
        RawOut.flush(buf.to_unsafe, len)
        LibC.abort
      end

      # The probe without an fd: the kernel copies one byte of our own memory
      # and refuses an unreadable page instead of faulting. Linux:
      # `process_vm_readv` against our own pid (EFAULT), which
      # `linux_thread_census.cr` already relies on; `getpid` each time so a
      # forked child asks about itself. Darwin: `mach_vm_read_overwrite` on our
      # own task. Both are syscalls, safe in the crash reporter's handler.
      private def self.fd_free_readable?(page : UInt64) : Bool
        {% if flag?(:darwin) %}
          byte = 0_u8
          got = 0_u64
          kr = Platform::LibMachVM.mach_vm_read_overwrite(Platform::LibMachVM.mach_task_self_, page, 1_u64,
            pointerof(byte).address, pointerof(got))
          kr == 0 && got == 1
        {% elsif flag?(:linux) %}
          byte = 0_u8
          Platform.read_self_memory(page, pointerof(byte).as(Void*), 1) == 1
        {% else %}
          false
        {% end %}
      end
    {% end %}

    # Kernel copies one byte from *page*; EFAULT ⇒ not readable (PROT_NONE / hole).
    #
    # Public because the crash reporter needs the same probe: `PoisonHolders`
    # walks fiber stacks word by word to report the *address* of a slot rather
    # than only its value, so it cannot go through `scan_range`, and a blind
    # read over a guard page from a signal handler is a second crash.
    #
    # A pipe write that fails for any reason but EFAULT says nothing about the
    # page — the program closed the fd, say — and goes to the fd-free probe
    # rather than call the page unreadable.
    def self.page_readable?(page : UInt64) : Bool
      {% if flag?(:win32) %}
        Platform.page_readable?(page)
      {% else %}
        wr = @@probe_wr
        if wr >= 0
          n = Gcry::OS.write(wr, Pointer(Void).new(page), 1)
          if n == 1
            buf = uninitialized UInt8
            LibC.read(@@probe_rd, pointerof(buf).as(Void*), 1)
            return true
          end
          return false if Errno.value == Errno::EFAULT
        end
        fd_free_readable?(page)
      {% end %}
    end

    # Zero [low, high) only on pages the kernel will let us read — fiber stacks
    # are thinly mapped; a blind Pointer.clear below SP can SEGV on a hole.
    def self.clear_range_safe(low : UInt64, high : UInt64) : UInt64
      return 0_u64 if low >= high
      if (high - low) > MAX_SCAN_BYTES
        @@oversize_skips &+= 1
        return 0_u64
      end

      ensure_probe_pipe

      cleared = 0_u64
      page = low & ~(PAGE_SIZE - 1)
      while page < high
        run_lo = page
        while page < high && page_readable?(page)
          page += PAGE_SIZE
        end
        if page > run_lo
          start = low > run_lo ? low : run_lo
          finish = page < high ? page : high
          if start < finish
            len = finish - start
            Pointer(UInt8).new(start).clear(len)
            cleared += len
          end
        else
          page += PAGE_SIZE
        end
      end
      cleared
    end
  end
end
