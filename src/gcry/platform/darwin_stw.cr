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
      UCONTEXT_SP_OFFSET  = THREAD_STATE_SP_OFFSET
      UCONTEXT_RSP_OFFSET = THREAD_STATE_SP_OFFSET

      MAX_STW_SP_SLOTS = 64

      @@stw_ids = uninitialized StaticArray(LibC::PthreadT, MAX_STW_SP_SLOTS)
      @@stw_sps = uninitialized StaticArray(UInt64, MAX_STW_SP_SLOTS)
      # GP registers of each suspended thread, slot-parallel to @@stw_ids.
      # `collect_scan` marks these because a suspended thread's register may hold
      # the only live copy of a reference — the stack scan cannot see a value the
      # compiler never spilled. Linux gets them from the signal ucontext; here
      # they come from the same `thread_get_state` that already reads SP.
      # StaticArray's length argument will not take an expression, so the
      # product is spelled out per arch: 64 slots × GREG_WORDS.
      {% if flag?(:aarch64) %}
        @@stw_gregs = uninitialized StaticArray(UInt64, 1984) # 64 × 31
      {% elsif flag?(:x86_64) %}
        @@stw_gregs = uninitialized StaticArray(UInt64, 1024) # 64 × 16
      {% else %}
        @@stw_gregs = uninitialized StaticArray(UInt64, 64)
      {% end %}
      # Per slot: were gregs actually captured this STW? Distinguishes "no
      # registers held anything" from "never recorded", which would otherwise
      # both read as a slot full of stale words from a previous collection.
      @@stw_greg_ok = uninitialized StaticArray(Bool, MAX_STW_SP_SLOTS)
      @@stw_claimed = uninitialized Atomic(UInt64)
      @@stw_booted = false
      @@stw_enabled = true
      @@stw_installed = false

      # Ports suspended in the current STW (for matched resume).
      @@stw_ports = uninitialized StaticArray(LibMach::ThreadAct, MAX_STW_SP_SLOTS)
      @@stw_port_count = 0

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
        @@stw_claimed.set(0_u64)
        @@stw_port_count = 0
        @@stw_booted = true
      end

      # Slot index for *id*, claiming a free one if it has none. -1 when the
      # table is full. Factored out of record_thread_sp so the SP and the GP
      # registers land in the same slot without claiming it twice.
      private def self.slot_for(id : LibC::PthreadT) : Int32
        ensure_stw_table
        claimed = @@stw_claimed.get(:acquire)
        i = 0
        while i < MAX_STW_SP_SLOTS
          if (claimed & (1_u64 << i)) != 0 && LibC.pthread_equal(@@stw_ids[i], id) != 0
            return i
          end
          i += 1
        end
        loop do
          claimed = @@stw_claimed.get(:acquire)
          i = 0
          while i < MAX_STW_SP_SLOTS
            bit = 1_u64 << i
            if (claimed & bit) == 0
              if @@stw_claimed.compare_and_set(claimed, claimed | bit)
                @@stw_ids[i] = id
                @@stw_sps[i] = 0_u64
                @@stw_greg_ok[i] = false
                return i
              end
              break
            end
            i += 1
          end
          return -1 if i >= MAX_STW_SP_SLOTS
        end
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
        src = state.as(UInt64*)
        base = i * GREG_WORDS
        j = 0
        while j < GREG_WORDS
          @@stw_gregs[base + j] = src[j]
          j += 1
        end
        @@stw_greg_ok[i] = true
      end

      def self.thread_sp(id : LibC::PthreadT) : Void*?
        return nil unless @@stw_enabled && @@stw_booted
        claimed = @@stw_claimed.get(:acquire)
        i = 0
        while i < MAX_STW_SP_SLOTS
          if (claimed & (1_u64 << i)) != 0 && LibC.pthread_equal(@@stw_ids[i], id) != 0
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
        claimed = @@stw_claimed.get(:acquire)
        i = 0
        while i < MAX_STW_SP_SLOTS
          if (claimed & (1_u64 << i)) != 0 && LibC.pthread_equal(@@stw_ids[i], id) != 0
            return unless @@stw_greg_ok[i]
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
        @@stw_claimed.set(0_u64, :release)
        i = 0
        while i < MAX_STW_SP_SLOTS
          @@stw_sps[i] = 0
          # Registers are per-STW like the SPs. Leaving them behind would let
          # the next collection mark a dead thread's stale words as roots.
          @@stw_greg_ok[i] = false
          i += 1
        end
      end

      def self.reset_stw_after_fork : Nil
        @@stw_installed = false
        ensure_stw_table
        @@stw_claimed.set(0_u64, :release)
        @@stw_port_count = 0
        i = 0
        while i < MAX_STW_SP_SLOTS
          @@stw_sps[i] = 0
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
                                            id : LibC::PthreadT) : Nil
        {% unless flag?(:x86_64) || flag?(:aarch64) %}
          return
        {% end %}
        return if port == 0

        state = uninitialized StaticArray(UInt32, 68)
        count = THREAD_STATE_COUNT
        kr = LibMach.thread_get_state(
          port,
          THREAD_STATE_FLAVOR,
          state.to_unsafe,
          pointerof(count),
        )
        return unless kr == KERN_SUCCESS

        record_thread_gregs(id, state.to_unsafe)

        if @@stw_enabled
          sp = (state.to_unsafe.as(UInt8*) + THREAD_STATE_SP_OFFSET).as(UInt64*).value
          record_thread_sp(id, sp) if sp != 0
        end
      end

      # Synchronous Mach stop of every Crystal OS thread except *current*.
      def self.stop_world_threads(current : ::Thread) : Nil
        ensure_stw_table
        @@stw_port_count = 0

        ::Thread.unsafe_each do |thread|
          next if thread == current

          pthread = thread.to_unsafe
          port = LibC.pthread_mach_thread_np(pthread)
          next if port == 0

          thread.@suspended.set(false)

          kr = LibMach.thread_suspend(port)
          if kr != KERN_SUCCESS
            resume_suspended_ports
            raise "gcry: thread_suspend failed (kr=#{kr})"
          end

          if @@stw_port_count < MAX_STW_SP_SLOTS
            @@stw_ports[@@stw_port_count] = port
            @@stw_port_count += 1
          end

          capture_thread_state(port, pthread)

          thread.@suspended.set(true)
        end
      end

      def self.start_world_threads(current : ::Thread) : Nil
        resume_suspended_ports

        # Clear Crystal suspended flags for threads we stopped.
        ::Thread.unsafe_each do |thread|
          next if thread == current
          thread.@suspended.set(false)
        end
      end

      private def self.resume_suspended_ports : Nil
        i = 0
        while i < @@stw_port_count
          port = @@stw_ports[i]
          if port != 0
            LibMach.thread_resume(port)
            @@stw_ports[i] = 0
          end
          i += 1
        end
        @@stw_port_count = 0
      end
    {% end %}
  end
end
