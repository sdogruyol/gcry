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
      {% elsif flag?(:x86_64) %}
        # x86_THREAD_STATE64 / x86_THREAD_STATE64_COUNT
        THREAD_STATE_FLAVOR = 4
        THREAD_STATE_COUNT  = 42_u32
        # Byte offset of __rsp within x86_thread_state64_t
        THREAD_STATE_SP_OFFSET = 56
      {% else %}
        THREAD_STATE_FLAVOR    = 0
        THREAD_STATE_COUNT     = 0_u32
        THREAD_STATE_SP_OFFSET = 0
      {% end %}

      # Back-compat names used by specs / samples (Linux ucontext era).
      UCONTEXT_SP_OFFSET  = THREAD_STATE_SP_OFFSET
      UCONTEXT_RSP_OFFSET = THREAD_STATE_SP_OFFSET

      MAX_STW_SP_SLOTS = 64

      @@stw_ids = uninitialized StaticArray(LibC::PthreadT, MAX_STW_SP_SLOTS)
      @@stw_sps = uninitialized StaticArray(UInt64, MAX_STW_SP_SLOTS)
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

      def self.record_thread_sp(id : LibC::PthreadT, sp : UInt64) : Nil
        ensure_stw_table
        claimed = @@stw_claimed.get(:acquire)
        i = 0
        while i < MAX_STW_SP_SLOTS
          if (claimed & (1_u64 << i)) != 0 && LibC.pthread_equal(@@stw_ids[i], id) != 0
            @@stw_sps[i] = sp
            return
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
                @@stw_sps[i] = sp
                return
              end
              break
            end
            i += 1
          end
          return if i >= MAX_STW_SP_SLOTS
        end
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

      def self.clear_thread_sps : Nil
        return unless @@stw_booted
        @@stw_claimed.set(0_u64, :release)
        i = 0
        while i < MAX_STW_SP_SLOTS
          @@stw_sps[i] = 0
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

      private def self.sp_from_mach_thread(port : LibMach::ThreadAct) : UInt64
        {% unless flag?(:x86_64) || flag?(:aarch64) %}
          return 0_u64
        {% end %}
        return 0_u64 if port == 0

        state = uninitialized StaticArray(UInt32, 68)
        count = THREAD_STATE_COUNT
        kr = LibMach.thread_get_state(
          port,
          THREAD_STATE_FLAVOR,
          state.to_unsafe,
          pointerof(count),
        )
        return 0_u64 unless kr == KERN_SUCCESS

        (state.to_unsafe.as(UInt8*) + THREAD_STATE_SP_OFFSET).as(UInt64*).value
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

          if @@stw_enabled
            sp = sp_from_mach_thread(port)
            record_thread_sp(pthread, sp) if sp != 0
          end

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
