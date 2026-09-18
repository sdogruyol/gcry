# Darwin STW via Mach thread_suspend / thread_resume (Boehm-style).
#
# Crystal's pthread_kill(SIGXFSZ)+sigsuspend path fails under HTTP load when
# the Monitor sits in kevent/Mach waits — wait_suspended spins forever and
# /gc-collect times out. Mach suspend is synchronous and does not need signals.
#
# SP clamp: thread_get_state after suspend → same SP table as Linux.

require "c/pthread"

lib LibC
  fun pthread_equal(t1 : PthreadT, t2 : PthreadT) : Int
  fun pthread_mach_thread_np(thread : PthreadT) : UInt32
end

lib LibMach
  alias ThreadAct = UInt32
  alias KernReturn = Int32
  alias MachMsgTypeNumber = UInt32

  fun thread_suspend(target : ThreadAct) : KernReturn
  fun thread_resume(target : ThreadAct) : KernReturn
  fun thread_get_state(
    target : ThreadAct,
    flavor : Int32,
    state : UInt32*,
    count : MachMsgTypeNumber*,
  ) : KernReturn
end

module Gcry
  module Platform
    {% if flag?(:darwin) %}
      KERN_SUCCESS = 0

      {% if flag?(:aarch64) %}
        # ARM_THREAD_STATE64 / ARM_THREAD_STATE64_COUNT
        THREAD_STATE_FLAVOR = 6
        THREAD_STATE_COUNT  = 68_u32
        # Byte offset of SP (__sp / __opaque_sp) within arm_thread_state64_t
        THREAD_STATE_SP_OFFSET = 248
        # Leading 64-bit words of arm_thread_state64_t that can hold a reference:
        #   [0..28] x0…x28, [29] fp, [30] lr, then [31] sp, [32] pc.
        # Stops before sp/pc — the stack is scanned by range and pc is not a
        # heap pointer.
        GREG_WORDS = 31
      {% elsif flag?(:x86_64) %}
        # x86_THREAD_STATE64 / x86_THREAD_STATE64_COUNT
        THREAD_STATE_FLAVOR = 4
        THREAD_STATE_COUNT  = 42_u32
        # Byte offset of __rsp within x86_thread_state64_t
        THREAD_STATE_SP_OFFSET = 56
        # [0..6] rax,rbx,rcx,rdx,rdi,rsi,rbp [7] rsp [8..15] r8…r15, then rip.
        # rsp is included rather than skipped: it costs one candidate that
        # `mark_root_candidate` rejects, and skipping it would put an
        # index-specific branch in the copy loop for no benefit.
        GREG_WORDS = 16
      {% else %}
        THREAD_STATE_FLAVOR    = 0
        THREAD_STATE_COUNT     = 0_u32
        THREAD_STATE_SP_OFFSET = 0
        GREG_WORDS             = 1
      {% end %}

      # Back-compat names used by specs / samples (Linux ucontext era).
      # These are `thread_get_state` offsets, **not** signal-ucontext offsets.
      UCONTEXT_SP_OFFSET  = THREAD_STATE_SP_OFFSET
      UCONTEXT_RSP_OFFSET = THREAD_STATE_SP_OFFSET

      # Signal `ucontext_t`, used by the crash report. Darwin keeps the
      # registers in `*(ucontext_t.uc_mcontext)`, a `__darwin_mcontext64`,
      # not inline the way glibc does. STW never reads this layout — it
      # uses `thread_get_state` — so these offsets exist only for the
      # handler. Transcribed from XNU `_ucontext.h` / `_mcontext.h`:
      #
      #   ucontext: onstack+sigmask (8) + stack_t (24) + uc_link (8) +
      #             uc_mcsize (8) = 48 to the mcontext pointer.
      #   mcontext: 16-byte exception state, then the same GP words
      #             `thread_get_state` returns (x0–x28+fp+lr / rax–r15).
      UCONTEXT_MCONTEXT_PTR_OFFSET = 48
      {% if flag?(:aarch64) %}
        MCONTEXT_GREGS_OFFSET =  16
        MCONTEXT_NGREGS       =  31
        MCONTEXT_FP_OFFSET    = 248 # x29
        MCONTEXT_LR_OFFSET    = 256 # x30
        MCONTEXT_SP_OFFSET    = 264
        MCONTEXT_PC_OFFSET    = 272
      {% elsif flag?(:x86_64) %}
        MCONTEXT_GREGS_OFFSET      =  16
        MCONTEXT_NGREGS            =  16
        MCONTEXT_FP_OFFSET         =  64 # rbp
        MCONTEXT_SP_OFFSET         =  72 # rsp
        MCONTEXT_PC_OFFSET         = 144 # rip
        MCONTEXT_FAULTVADDR_OFFSET =   8
      {% else %}
        MCONTEXT_GREGS_OFFSET = 0
        MCONTEXT_NGREGS       = 0
        MCONTEXT_FP_OFFSET    = 0
        MCONTEXT_SP_OFFSET    = 0
        MCONTEXT_PC_OFFSET    = 0
      {% end %}

      # The capture table lives in `Gcry::StwSlots`, shared with Windows and
      # covered by `spec/stw_slots_spec.cr` — it used to be four static arrays
      # and a 64-bit claim mask here, and the mask *was* the bound: past 64
      # threads `slot_for` returned -1 and the thread was suspended with **no
      # registers captured**, which on this platform loses them outright
      # because `thread_get_state` is their only copy. Growing it in place here
      # crashed CI once and could not be debugged from this host; that is why
      # the table moved somewhere a spec can reach it
      # (`bench/log/linux/2026-09-17-darwin-64-thread-cliff/HALF2-REVERT.md`).
      #
      # `collect_scan` marks those registers because a suspended thread's
      # register may hold the only live copy of a reference, and the stack scan
      # cannot see a value the compiler never spilled.

      # The pre-fix resume table, reachable only through
      # `GCRY_STW_BOUNDED_RESUME=1`, and fixed at what shipped.
      STW_BOUNDED_RESUME_SLOTS = 64

      # PROBE ONLY. The exact declarations the growable table removed, back in
      # their original module, types and order — the same-size pad round did not
      # reproduce them byte for byte. Kept alive by `legacy_touch` so the linker
      # cannot drop them. Green here means the Darwin crash follows the missing
      # statics (layout), not the table's code.
      MAX_STW_SP_SLOTS = 64
      @@stw_ids = uninitialized StaticArray(LibC::PthreadT, MAX_STW_SP_SLOTS)
      @@stw_sps = uninitialized StaticArray(UInt64, MAX_STW_SP_SLOTS)
      {% if flag?(:aarch64) %}
        @@stw_gregs = uninitialized StaticArray(UInt64, 1984)
      {% elsif flag?(:x86_64) %}
        @@stw_gregs = uninitialized StaticArray(UInt64, 1024)
      {% else %}
        @@stw_gregs = uninitialized StaticArray(UInt64, 64)
      {% end %}
      @@stw_greg_ok = uninitialized StaticArray(Bool, MAX_STW_SP_SLOTS)
      @@stw_claimed = uninitialized Atomic(UInt64)

      def self.legacy_touch : UInt64
        @@stw_ids[0] = LibC.pthread_self
        @@stw_sps[0] = @@stw_sps[0] &+ 1
        @@stw_gregs[0] = @@stw_gregs[0] &+ 1
        @@stw_greg_ok[0] = true
        @@stw_claimed.set(0_u64)
        @@stw_sps[0]
      end

      @@stw_booted = false
      @@stw_enabled = true
      @@stw_installed = false

      # Ports suspended in the current STW. **Not** the shipped resume path any
      # more — see `resume_suspended_threads` — and written only when
      # `GCRY_STW_BOUNDED_RESUME=1` asks for the pre-fix behaviour, which is the
      # red arm for `make darwin-stw-resume`.
      @@stw_ports = uninitialized StaticArray(LibMach::ThreadAct, STW_BOUNDED_RESUME_SLOTS)
      @@stw_port_count = 0
      @@stw_bounded_resume = uninitialized Bool

      # Threads this process has suspended and resumed for a stop, cumulative
      # and `KERN_SUCCESS`-only on both sides. The stop and the resume walk the
      # same predicate, so these are equal after every restarted world, and the
      # two ways that can break are both defects: fewer resumes means a thread
      # left frozen (the bounded-table bug), more means gcry resumed a thread
      # something else had suspended. `make darwin-stw-resume` asserts equality
      # for that reason rather than `resumed >= suspended`.
      @@stw_threads_suspended = uninitialized UInt64
      @@stw_threads_resumed = uninitialized UInt64

      def self.stw_sp_clamp_enabled? : Bool
        @@stw_enabled
      end

      def self.stw_sp_clamp_enabled=(value : Bool) : Bool
        @@stw_enabled = value
      end

      def self.stw_sp_capture_installed? : Bool
        @@stw_installed
      end

      private def self.ensure_stw_table : Nil
        return if @@stw_booted
        @@stw_port_count = 0
        @@stw_threads_suspended = 0_u64
        @@stw_threads_resumed = 0_u64
        @@stw_bounded_resume = false
        @@stw_booted = true
        StwSlots.configure(GREG_WORDS)
      end

      def self.stw_capture_no_slot : UInt64
        StwSlots.no_slot
      end

      def self.stw_slot_capacity : Int32
        StwSlots.capacity
      end

      # `GCRY_STW_FIXED_SLOTS=1`: pin the capture table at the 64 slots that
      # shipped, which is the red arm for `make stw-capture-coverage`.
      def self.stw_fixed_slots=(value : Bool) : Bool
        ensure_stw_table
        StwSlots.pinned = value
      end

      def self.stw_fixed_slots? : Bool
        StwSlots.pinned?
      end

      def self.stw_threads_suspended : UInt64
        @@stw_booted ? @@stw_threads_suspended : 0_u64
      end

      def self.stw_threads_resumed : UInt64
        @@stw_booted ? @@stw_threads_resumed : 0_u64
      end

      # `GCRY_STW_BOUNDED_RESUME=1`: resume from the 64-entry port table, as
      # this platform did until the thread list became the record. Boots the
      # table first, so the knob survives being set before the first stop.
      def self.stw_bounded_resume=(value : Bool) : Bool
        ensure_stw_table
        @@stw_bounded_resume = value
      end

      def self.stw_bounded_resume? : Bool
        @@stw_booted && @@stw_bounded_resume
      end

      # Slot index for *id*, claiming a free one if it has none. -1 when the
      # table is full, which now means the allocator refused to grow it or
      # `GCRY_STW_FIXED_SLOTS=1` pinned it.
      #
      # `pthread_t` is an opaque pointer here, so its address is its identity —
      # which is what `pthread_equal` compares — and the shared table keys on a
      # plain `UInt64`.
      private def self.slot_for(id : LibC::PthreadT) : Int32
        ensure_stw_table
        StwSlots.slot_for(id.address.to_u64)
      end

      def self.record_thread_sp(id : LibC::PthreadT, sp : UInt64, uctx : Void* = Pointer(Void).null) : Nil
        StwSlots.record_sp(slot_for(id), sp)
      end

      def self.thread_sp(id : LibC::PthreadT) : Void*?
        return nil unless @@stw_enabled && @@stw_booted
        sp = StwSlots.sp(id.address.to_u64)
        return nil if sp == 0
        Pointer(Void).new(sp)
      end

      # GP registers captured for *id* at suspend. Yields nothing when the slot
      # was never filled this STW — a stale slot must not be marked, and an
      # unfilled one must not read as "no roots".
      def self.each_thread_greg(id : LibC::PthreadT, & : Void* ->) : Nil
        return unless @@stw_booted
        StwSlots.each_greg(id.address.to_u64) do |word|
          yield Pointer(Void).new(word)
        end
      end

      def self.clear_thread_sps : Nil
        return unless @@stw_booted
        # Registers are per-STW like the SPs. Leaving them behind would let the
        # next collection mark a dead thread's stale words as roots.
        StwSlots.clear
      end

      def self.reset_stw_after_fork : Nil
        @@stw_installed = false
        ensure_stw_table
        StwSlots.clear
        @@stw_port_count = 0
        i = 0
        while i < STW_BOUNDED_RESUME_SLOTS
          @@stw_ports[i] = 0
          i += 1
        end
      end

      # Unused on Mach path; kept for API parity with Linux.
      def self.sp_from_ucontext(uctx : Void*) : UInt64
        0_u64
      end

      def self.rsp_from_ucontext(uctx : Void*) : UInt64
        0_u64
      end

      # Mark Mach STW + SP table ready (no signal handler).
      def self.install_stw_sp_capture : Nil
        {% unless flag?(:x86_64) || flag?(:aarch64) %}
          return
        {% end %}
        return if @@stw_installed
        ensure_stw_table
        @@stw_installed = true
      end

      # One `thread_get_state` per suspended thread, feeding both root sources.
      #
      # The SP half is the clamp and is knob-gated. The register half is not:
      # `GCRY_DISABLE_SP_CLAMP` trades precision for speed, whereas skipping the
      # registers drops roots, so it is captured whatever the clamp says.
      private def self.capture_thread_state(port : LibMach::ThreadAct,
                                            id : LibC::PthreadT,
                                            slot : Int32) : Nil
        {% unless flag?(:x86_64) || flag?(:aarch64) %}
          return
        {% end %}
        return if port == 0
        return if slot < 0

        state = uninitialized StaticArray(UInt32, 68)
        count = THREAD_STATE_COUNT
        kr = LibMach.thread_get_state(
          port,
          THREAD_STATE_FLAVOR,
          state.to_unsafe,
          pointerof(count),
        )
        return unless kr == KERN_SUCCESS

        # Both halves land in the slot the caller already claimed. They used to
        # re-derive it through a linear scan each — twice per thread per stop,
        # which is O(n^2) inside the pause and the next cliff once the 64-slot
        # bound came off.
        StwSlots.record_gregs(slot, state.to_unsafe.as(UInt64*), GREG_WORDS)

        if @@stw_enabled
          sp = (state.to_unsafe.as(UInt8*) + THREAD_STATE_SP_OFFSET).as(UInt64*).value
          StwSlots.record_sp(slot, sp) if sp != 0
        end
      end

      # Synchronous Mach stop of every Crystal OS thread except *current*.
      def self.stop_world_threads(current : ::Thread) : Nil
        ensure_stw_table
        @@stw_port_count = 0

        # Size the capture table **before** suspending anyone: `malloc` with the
        # world stopped is the 2026-08-10 six-hour hang, and here nothing is
        # frozen yet. The slack covers threads born during the stop — the list
        # does move, which is why `birth_grace.cr` exists.
        n = 0
        ::Thread.unsafe_each { n += 1 }
        StwSlots.reserve(n + 8)

        ::Thread.unsafe_each do |thread|
          next if thread == current

          pthread = thread.to_unsafe
          port = LibC.pthread_mach_thread_np(pthread)
          next if port == 0

          thread.@suspended.set(false)

          kr = LibMach.thread_suspend(port)
          if kr != KERN_SUCCESS
            resume_suspended_threads(current)
            raise "gcry: thread_suspend failed (kr=#{kr})"
          end
          @@stw_threads_suspended &+= 1

          # Only the control arm needs the table: the shipped resume walks the
          # thread list. Recording unconditionally would keep a bound in the
          # stop that nothing reads.
          if @@stw_bounded_resume && @@stw_port_count < STW_BOUNDED_RESUME_SLOTS
            @@stw_ports[@@stw_port_count] = port
            @@stw_port_count += 1
          end

          capture_thread_state(port, pthread, slot_for(pthread))

          thread.@suspended.set(true)
        end
      end

      def self.start_world_threads(current : ::Thread) : Nil
        if @@stw_bounded_resume
          resume_suspended_ports
          # Clear Crystal suspended flags for threads we stopped.
          ::Thread.unsafe_each do |thread|
            next if thread == current
            thread.@suspended.set(false)
          end
          return
        end

        resume_suspended_threads(current)
      end

      # Resume by walking the thread list rather than a table of ports.
      #
      # `stop_world_threads` suspends **every** non-current thread whose Mach
      # port is non-zero, so that predicate is the record and the two walks
      # cover the same set by construction — with no fixed bound between an
      # unbounded stop and a 64-entry resume. That mismatch left the 65th thread
      # and up suspended forever, which is a hang rather than a slow collection
      # (`bench/log/linux/2026-09-17-darwin-64-thread-cliff/`).
      #
      # Only a `KERN_SUCCESS` is counted. `thread_resume` on a thread whose
      # suspend count is already zero returns `KERN_FAILURE` and does nothing,
      # so a thread born during the stop costs an inert call rather than a
      # spurious wake; and if something outside gcry had suspended it, the
      # resume *would* succeed and show up as `stw_threads_resumed` overtaking
      # `stw_threads_suspended`.
      private def self.resume_suspended_threads(current : ::Thread) : Nil
        ::Thread.unsafe_each do |thread|
          next if thread == current
          port = LibC.pthread_mach_thread_np(thread.to_unsafe)
          next if port == 0
          @@stw_threads_resumed &+= 1 if LibMach.thread_resume(port) == KERN_SUCCESS
          thread.@suspended.set(false)
        end
      end

      # Pre-fix resume, reachable only through `GCRY_STW_BOUNDED_RESUME=1`.
      private def self.resume_suspended_ports : Nil
        i = 0
        while i < @@stw_port_count
          port = @@stw_ports[i]
          if port != 0
            @@stw_threads_resumed &+= 1 if LibMach.thread_resume(port) == KERN_SUCCESS
            @@stw_ports[i] = 0
          end
          i += 1
        end
        @@stw_port_count = 0
      end
    {% end %}
  end
end
