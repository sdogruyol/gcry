# Capture SP at STW suspend so other-thread stack scans can skip unused
# below-SP words (classic conservative false retention).
#
# Replaces Crystal's SIG_SUSPEND handler after init_suspend_resume: same
# suspended-flag + sigsuspend(SIG_RESUME) dance, plus Darwin ucontext SP → table.
#
# Darwin: Crystal uses SIGXFSZ / SIGXCPU (no SIGRTMIN). ucontext_t.uc_mcontext
# is a pointer; SP lives in mcontext->__ss.__sp (arm64) / __rsp (x86_64).

require "c/signal"
require "c/pthread"

lib LibC
  fun pthread_equal(t1 : PthreadT, t2 : PthreadT) : Int
end

module Gcry
  module Platform
    {% if flag?(:darwin) %}
      # Must match Crystal::System::Thread SIG_* on Darwin.
      STW_SIG_SUSPEND = LibC::SIGXFSZ
      STW_SIG_RESUME  = LibC::SIGXCPU

      # Byte offset of uc_mcontext pointer inside Darwin ucontext_t.
      UCONTEXT_MCONTEXT_OFFSET = 48

      # Byte offset of SP inside Darwin mcontext64 (__ss.__sp / __ss.__rsp).
      {% if flag?(:aarch64) %}
        MCONTEXT_SP_OFFSET = 264
      {% elsif flag?(:x86_64) %}
        MCONTEXT_SP_OFFSET = 72
      {% else %}
        MCONTEXT_SP_OFFSET = 0
      {% end %}

      # Back-compat alias used by specs / samples (Linux name).
      UCONTEXT_SP_OFFSET  = UCONTEXT_MCONTEXT_OFFSET
      UCONTEXT_RSP_OFFSET = UCONTEXT_SP_OFFSET

      MAX_STW_SP_SLOTS = 64

      @@stw_ids = uninitialized StaticArray(LibC::PthreadT, MAX_STW_SP_SLOTS)
      @@stw_sps = uninitialized StaticArray(UInt64, MAX_STW_SP_SLOTS)
      @@stw_claimed = uninitialized Atomic(UInt64)
      @@stw_booted = false
      @@stw_enabled = true
      @@stw_installed = false

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
        i = 0
        while i < MAX_STW_SP_SLOTS
          @@stw_sps[i] = 0
          i += 1
        end
      end

      # Follow Darwin ucontext_t → mcontext → SP.
      def self.sp_from_ucontext(uctx : Void*) : UInt64
        return 0_u64 if uctx.null?
        {% if flag?(:x86_64) || flag?(:aarch64) %}
          mctx = (uctx + UCONTEXT_MCONTEXT_OFFSET).as(Void**).value
          return 0_u64 if mctx.null?
          (mctx + MCONTEXT_SP_OFFSET).as(UInt64*).value
        {% else %}
          0_u64
        {% end %}
      end

      def self.rsp_from_ucontext(uctx : Void*) : UInt64
        sp_from_ucontext(uctx)
      end

      def self.install_stw_sp_capture : Nil
        {% unless flag?(:x86_64) || flag?(:aarch64) %}
          return
        {% end %}
        return if @@stw_installed
        ensure_stw_table

        action = LibC::Sigaction.new
        action.sa_flags = LibC::SA_SIGINFO
        action.sa_sigaction = LibC::SigactionHandlerT.new do |_sig, _info, uctx|
          sp = Platform.sp_from_ucontext(uctx)
          Platform.record_thread_sp(LibC.pthread_self, sp) if sp != 0

          ::Thread.current.@suspended.set(true)

          mask = uninitialized LibC::SigsetT
          LibC.sigfillset(pointerof(mask))
          LibC.sigdelset(pointerof(mask), STW_SIG_RESUME)
          LibC.sigsuspend(pointerof(mask))
        end
        LibC.sigemptyset(pointerof(action.@sa_mask))
        LibC.sigaction(STW_SIG_SUSPEND, pointerof(action), nil)
        @@stw_installed = true
      end
    {% end %}
  end
end
