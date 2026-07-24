# Capture RSP at STW suspend so other-thread stack scans can skip unused
# below-SP words (classic conservative false retention).
#
# Replaces Crystal's SIG_SUSPEND handler after init_suspend_resume: same
# suspended-flag + sigsuspend(SIG_RESUME) dance, plus ucontext RSP → table.

require "c/signal"
require "c/pthread"

lib LibC
  fun pthread_equal(t1 : PthreadT, t2 : PthreadT) : Int
end

module Gcry
  module Platform
    # Must match Crystal::System::Thread SIG_* on this platform (linux-gnu).
    STW_SIG_SUSPEND = LibC::SIGPWR
    STW_SIG_RESUME  = {% if LibC.has_constant?(:SIGRTMIN) %}
                        LibC::SIGRTMIN + 5
                      {% else %}
                        LibC::SIGXCPU
                      {% end %}

    # glibc x86_64 ucontext_t: uc_mcontext @ 40, gregs[REG_RSP=15] @ +120 → 160.
    UCONTEXT_RSP_OFFSET = 160

    MAX_STW_SP_SLOTS = 64

    # Async-signal-safe SP table (no Hash / Array growth).
    @@stw_ids = uninitialized StaticArray(LibC::PthreadT, MAX_STW_SP_SLOTS)
    @@stw_sps = uninitialized StaticArray(UInt64, MAX_STW_SP_SLOTS)
    # Bitmask of occupied slots. Must be `uninitialized` — a class-var
    # `Atomic(...).new` goes through Crystal.once and SIGSEGVs in GC.init
    # before Thread/Fiber exist. Atomic-in-StaticArray also fails (CAS on copy).
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

    # Record SP for the interrupted thread (signal-handler safe).
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
      # Claim a free slot via CAS on the bitmask.
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
            break # retry outer loop with fresh claimed
          end
          i += 1
        end
        return if i >= MAX_STW_SP_SLOTS # table full
      end
    end

    # Lookup SP captured at last suspend for *id*.
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

    def self.rsp_from_ucontext(uctx : Void*) : UInt64
      return 0_u64 if uctx.null?
      {% if flag?(:x86_64) %}
        # Fixed glibc layout — avoid Crystal StackT padding mismatches.
        (uctx + UCONTEXT_RSP_OFFSET).as(UInt64*).value
      {% else %}
        0_u64
      {% end %}
    end

    # Install after Crystal::System::Thread.init_suspend_resume.
    def self.install_stw_sp_capture : Nil
      {% unless flag?(:linux) && flag?(:x86_64) %}
        return
      {% end %}
      return if @@stw_installed
      ensure_stw_table

      action = LibC::Sigaction.new
      action.sa_flags = LibC::SA_SIGINFO
      action.sa_sigaction = LibC::SigactionHandlerT.new do |_sig, _info, uctx|
        sp = Platform.rsp_from_ucontext(uctx)
        Platform.record_thread_sp(LibC.pthread_self, sp) if sp != 0

        # Mirror Crystal::System::Thread suspend handler.
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
  end
end
