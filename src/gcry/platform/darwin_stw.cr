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

      # Where the capture table starts. It used to be a hard maximum, and past
      # it `slot_for` returned -1: the thread was suspended with **no SP clamp
      # and no registers captured**. The SP half of that is conservative — with
      # no clamp the root scan walks the whole stack — but on this platform the
      # registers come from `thread_get_state` and live nowhere else, so a
      # reference held only in the 65th thread's registers was not a root
      # (`bench/log/linux/2026-09-17-darwin-64-thread-cliff/`). The table now
      # grows with the thread count.
      STW_INITIAL_SLOTS = 64

      # The pre-fix resume table, reachable only through
      # `GCRY_STW_BOUNDED_RESUME=1`, and fixed at what shipped.
      STW_BOUNDED_RESUME_SLOTS = 64

      # `LibC`-allocated rather than static, and grown **before the first
      # suspend** — `malloc` with the world stopped is the 2026-08-10six-hour
      # hang. Same shape and the same reason as `linux_stack.cr`'s bounds table.
      #
      # Static arrays were what forced the bound: the greg row is GREG_WORDS
      # wide per slot, so a table big enough for a thousand threads would put
      # a quarter of a megabyte of zeros in BSS — which is a **conservative
      # static root range** on this platform, scanned every collection, and
      # exactly what made a 256 KiB report buffer shift chunk residency on the
      # aarch64 runner (`segv_report.cr`).
      @@stw_capacity = 0
      @@stw_ids = Pointer(LibC::PthreadT).null
      @@stw_sps = Pointer(UInt64).null
      # GP registers of each suspended thread, slot-parallel to @@stw_ids.
      # `collect_scan` marks these because a suspended thread's register may hold
      # the only live copy of a reference — the stack scan cannot see a value the
      # compiler never spilled. Linux gets them from the signal ucontext, which
      # sits on the interrupted thread's own stack and is therefore covered by a
      # conservative stack walk even with no slot; here they come from the same
      # `thread_get_state` that reads SP, and nothing else has a copy.
      @@stw_gregs = Pointer(UInt64).null
      # Per slot: were gregs actually captured this STW? Distinguishes "no
      # registers held anything" from "never recorded", which would otherwise
      # both read as a slot full of stale words from a previous collection.
      @@stw_greg_ok = Pointer(UInt8).null
      # One byte per slot, not a 64-bit mask. The mask *was* the bound — a
      # `UInt64` cannot address a 65th slot — and the CAS it needed is not
      # needed here at all: on this platform `slot_for` runs only on the
      # collector, from `stop_world_threads`, one thread at a time. Linux is the
      # platform where the suspend handler claims from every thread at once, and
      # that is where the atomic belongs.
      @@stw_claimed = Pointer(UInt8).null
      # `GCRY_STW_FIXED_SLOTS=1`: never grow, which is the pre-fix bound and the
      # red arm for `make stw-capture-coverage`.
      @@stw_fixed_slots = uninitialized Bool
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

      # Slot claims that found the table full, cumulative for the life of the
      # process. A thread with no slot is still suspended and still scanned —
      # it just loses its SP clamp and its registers, so a reference held only
      # in the 65th thread's registers stops being a root. Now that the table
      # grows, this is **expected to stay zero**, and `make stw-capture-coverage`
      # asserts that; it moves only when the allocator refuses a bigger table or
      # when `GCRY_STW_FIXED_SLOTS=1` pins it.
      #
      # Counts failed *claims*, not threads: `capture_thread_state` asks once
      # for the SP and once for the registers, so one uncovered thread adds
      # two. The distinction does not matter to a zero and would cost a second
      # counter to remove.
      @@stw_capture_no_slot = uninitialized UInt64

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
        @@stw_capture_no_slot = 0_u64
        @@stw_threads_suspended = 0_u64
        @@stw_threads_resumed = 0_u64
        @@stw_bounded_resume = false
        @@stw_fixed_slots = false
        @@stw_booted = true
        grow_stw_table(STW_INITIAL_SLOTS)
      end

      # Grows the capture table to at least *want* slots, doubling. Returns
      # false when the allocator refuses and leaves the old table in place —
      # the collection is **not** failed for that, it captures what fits and
      # `stw_capture_no_slot` counts the rest. Refusing to collect is what
      # Windows did with this bound and it trades a missed root for an
      # unbounded heap.
      #
      # No copy: every slot is per-STW (`clear_thread_sps` wipes them) and
      # nothing reads the table between collections, so growth frees and
      # reallocates. Safe only because callers grow before the first suspend.
      private def self.grow_stw_table(want : Int32) : Bool
        return true if want <= @@stw_capacity
        cap = @@stw_capacity < STW_INITIAL_SLOTS ? STW_INITIAL_SLOTS : @@stw_capacity
        while cap < want
          cap *= 2
        end

        ids = LibC.malloc(LibC::SizeT.new(cap.to_u64 * sizeof(LibC::PthreadT)))
        sps = LibC.malloc(LibC::SizeT.new(cap.to_u64 * sizeof(UInt64)))
        gregs = LibC.malloc(LibC::SizeT.new(cap.to_u64 * GREG_WORDS.to_u64 * sizeof(UInt64)))
        greg_ok = LibC.malloc(LibC::SizeT.new(cap.to_u64))
        claimed = LibC.malloc(LibC::SizeT.new(cap.to_u64))
        if ids.null? || sps.null? || gregs.null? || greg_ok.null? || claimed.null?
          LibC.free(ids)
          LibC.free(sps)
          LibC.free(gregs)
          LibC.free(greg_ok)
          LibC.free(claimed)
          return false
        end

        LibC.free(@@stw_ids.as(Void*))
        LibC.free(@@stw_sps.as(Void*))
        LibC.free(@@stw_gregs.as(Void*))
        LibC.free(@@stw_greg_ok.as(Void*))
        LibC.free(@@stw_claimed.as(Void*))

        @@stw_ids = ids.as(LibC::PthreadT*)
        @@stw_sps = sps.as(UInt64*)
        @@stw_gregs = gregs.as(UInt64*)
        @@stw_greg_ok = greg_ok.as(UInt8*)
        @@stw_claimed = claimed.as(UInt8*)
        @@stw_capacity = cap

        # Only the two flag arrays need initialising: a slot's id, SP and greg
        # row are read only through a claimed, filled slot.
        i = 0
        while i < cap
          @@stw_claimed[i] = 0_u8
          @@stw_greg_ok[i] = 0_u8
          i += 1
        end
        true
      end

      # Slots the capture table can hold. Reported so a harness can say whether
      # a zero `stw_capture_no_slot` means "covered" or "never grew".
      def self.stw_slot_capacity : Int32
        @@stw_capacity
      end

      # `GCRY_STW_FIXED_SLOTS=1`: pin the table at its initial size, which is
      # the pre-fix bound. Boots the table first so the knob survives being set
      # before the first stop.
      def self.stw_fixed_slots=(value : Bool) : Bool
        ensure_stw_table
        @@stw_fixed_slots = value
      end

      def self.stw_fixed_slots? : Bool
        @@stw_booted && @@stw_fixed_slots
      end

      def self.stw_capture_no_slot : UInt64
        @@stw_booted ? @@stw_capture_no_slot : 0_u64
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
      # Plain loads and stores: the collector is the only caller and it calls
      # from `stop_world_threads`, one thread at a time. The CAS this used to do
      # was defensive on this platform and it is the reason the table was a
      # 64-bit mask.
      private def self.slot_for(id : LibC::PthreadT) : Int32
        ensure_stw_table
        i = 0
        while i < @@stw_capacity
          if @@stw_claimed[i] != 0 && LibC.pthread_equal(@@stw_ids[i], id) != 0
            return i
          end
          i += 1
        end
        i = 0
        while i < @@stw_capacity
          if @@stw_claimed[i] == 0
            @@stw_claimed[i] = 1_u8
            @@stw_ids[i] = id
            @@stw_sps[i] = 0_u64
            @@stw_greg_ok[i] = 0_u8
            return i
          end
          i += 1
        end
        @@stw_capture_no_slot &+= 1
        -1
      end

      def self.record_thread_sp(id : LibC::PthreadT, sp : UInt64, uctx : Void* = Pointer(Void).null) : Nil
        i = slot_for(id)
        return if i < 0
        @@stw_sps[i] = sp
      end

      # Copy the GP words of a just-read thread state into *id*'s slot.
      # *state* is the raw arm_thread_state64_t / x86_thread_state64_t buffer.
      private def self.record_thread_gregs(id : LibC::PthreadT, state : UInt32*) : Nil
        i = slot_for(id)
        return if i < 0
        record_thread_gregs_at(i, state)
      end

      # Same, for a slot the caller already has. `stop_world_threads` walks the
      # threads itself, so it can hand the index down instead of having both
      # halves of the capture re-derive it: `slot_for` is a linear scan and was
      # called twice per thread, which is O(n^2) inside the pause and the next
      # cliff once the 64-slot bound came off.
      private def self.record_thread_gregs_at(i : Int32, state : UInt32*) : Nil
        src = state.as(UInt64*)
        base = i * GREG_WORDS
        j = 0
        while j < GREG_WORDS
          @@stw_gregs[base + j] = src[j]
          j += 1
        end
        @@stw_greg_ok[i] = 1_u8
      end

      def self.thread_sp(id : LibC::PthreadT) : Void*?
        return nil unless @@stw_enabled && @@stw_booted
        i = 0
        while i < @@stw_capacity
          if @@stw_claimed[i] != 0 && LibC.pthread_equal(@@stw_ids[i], id) != 0
            sp = @@stw_sps[i]
            return nil if sp == 0
            return Pointer(Void).new(sp)
          end
          i += 1
        end
        nil
      end

      # GP registers captured for *id* at suspend. Yields nothing when the slot
      # was never filled this STW — a stale slot must not be marked, and an
      # unfilled one must not read as "no roots".
      def self.each_thread_greg(id : LibC::PthreadT, & : Void* ->) : Nil
        return unless @@stw_booted
        i = 0
        while i < @@stw_capacity
          if @@stw_claimed[i] != 0 && LibC.pthread_equal(@@stw_ids[i], id) != 0
            return if @@stw_greg_ok[i] == 0
            base = i * GREG_WORDS
            j = 0
            while j < GREG_WORDS
              word = @@stw_gregs[base + j]
              yield Pointer(Void).new(word) unless word == 0
              j += 1
            end
            return
          end
          i += 1
        end
      end

      def self.clear_thread_sps : Nil
        return unless @@stw_booted
        i = 0
        while i < @@stw_capacity
          @@stw_claimed[i] = 0_u8
          @@stw_sps[i] = 0_u64
          # Registers are per-STW like the SPs. Leaving them behind would let
          # the next collection mark a dead thread's stale words as roots.
          @@stw_greg_ok[i] = 0_u8
          i += 1
        end
      end

      def self.reset_stw_after_fork : Nil
        @@stw_installed = false
        ensure_stw_table
        clear_thread_sps
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

        record_thread_gregs_at(slot, state.to_unsafe)

        if @@stw_enabled
          sp = (state.to_unsafe.as(UInt8*) + THREAD_STATE_SP_OFFSET).as(UInt64*).value
          @@stw_sps[slot] = sp if sp != 0
        end
      end

      # Synchronous Mach stop of every Crystal OS thread except *current*.
      def self.stop_world_threads(current : ::Thread) : Nil
        ensure_stw_table
        @@stw_port_count = 0

        # Size the capture table **before** suspending anyone. `malloc` with the
        # world stopped is the 2026-08-10 six-hour hang; here nothing is frozen
        # yet, so the allocator's own lock is safe to take. The slack is for
        # threads that appear between this count and the loop below — the list
        # does move during a stop, which is why `birth_grace.cr` exists.
        unless @@stw_fixed_slots
          n = 0
          ::Thread.unsafe_each { n += 1 }
          grow_stw_table(n + 8)
        end

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
