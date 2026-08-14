# Capture SP at STW suspend so other-thread stack scans can skip unused
# below-SP words (classic conservative false retention).
#
# Replaces Crystal's SIG_SUSPEND handler after init_suspend_resume: same
# suspended-flag + sigsuspend(SIG_RESUME) dance, plus ucontext SP → table.
#
# Linux gnu: x86_64 and aarch64. Fixed glibc offsets avoid Crystal StackT /
# SigsetT padding mismatches when reading through typed ucontext_t.

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

    # Byte offset of the saved stack pointer inside glibc ucontext_t.
    # x86_64: uc_mcontext.gregs[REG_RSP] (see linux_stw history / samples).
    # aarch64: uc_mcontext.sp — uc_mcontext @ 176 (16-aligned after sigset),
    #          sp @ +256 within mcontext (fault_address + regs[31]).
    {% if flag?(:x86_64) %}
      UCONTEXT_SP_OFFSET = 160
      # glibc x86_64: offsetof(ucontext_t, uc_mcontext.gregs) == 40, NGREG == 23.
      UCONTEXT_GREGS_OFFSET = 40
      UCONTEXT_NGREGS       = 23
    {% elsif flag?(:aarch64) %}
      UCONTEXT_SP_OFFSET = 432
      # `sigcontext` is { fault_address, regs[31], sp, pc, pstate, ... } and
      # `uc_mcontext` sits at 176, so regs[0] is at 176 + 8 = 184 and the 31
      # words are x0…x30 (x29 fp, x30 lr) — no sp or pc, which is right: the
      # stack is scanned by range and pc is not a heap pointer.
      #
      # The offset is cross-checked against a constant already known good rather
      # than trusted on its own: sp follows regs[30], so 184 + 31*8 = 432, which
      # is the SP offset above that the aarch64 clamp has been using in
      # production. If one is right the other is.
      #
      # This read "skip full mcontext register dump on aarch64 for now (SP clamp
      # only)" until 2026-08-14. `collect_scan` calls `each_thread_greg` because
      # a register can hold the only live copy of a reference, so "for now" was
      # the same dropped-root defect Darwin had — found by `make greg-roots` on
      # its first CI run, reporting 0 candidates with a thread suspended.
      UCONTEXT_GREGS_OFFSET = 184
      UCONTEXT_NGREGS       =  31
    {% else %}
      UCONTEXT_SP_OFFSET    = 0
      UCONTEXT_GREGS_OFFSET = 0
      UCONTEXT_NGREGS       = 0
    {% end %}

    # Back-compat alias used by specs / samples.
    UCONTEXT_RSP_OFFSET = UCONTEXT_SP_OFFSET

    MAX_STW_SP_SLOTS = 64
    MAX_STW_GREGS    = 32

    # Async-signal-safe SP + GP-register table (no Hash / Array growth).
    @@stw_ids = uninitialized StaticArray(LibC::PthreadT, MAX_STW_SP_SLOTS)
    @@stw_sps = uninitialized StaticArray(UInt64, MAX_STW_SP_SLOTS)
    @@stw_gregs = uninitialized StaticArray(StaticArray(UInt64, MAX_STW_GREGS), MAX_STW_SP_SLOTS)
    @@stw_ngregs = uninitialized StaticArray(Int32, MAX_STW_SP_SLOTS)
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

    # Record SP (+ GP regs) for the interrupted thread (signal-handler safe).
    def self.record_thread_sp(id : LibC::PthreadT, sp : UInt64, uctx : Void* = Pointer(Void).null) : Nil
      ensure_stw_table
      claimed = @@stw_claimed.get(:acquire)
      i = 0
      while i < MAX_STW_SP_SLOTS
        if (claimed & (1_u64 << i)) != 0 && LibC.pthread_equal(@@stw_ids[i], id) != 0
          @@stw_sps[i] = sp
          copy_ucontext_gregs(i, uctx)
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
              copy_ucontext_gregs(i, uctx)
              return
            end
            break # retry outer loop with fresh claimed
          end
          i += 1
        end
        return if i >= MAX_STW_SP_SLOTS # table full
      end
    end

    private def self.copy_ucontext_gregs(slot : Int32, uctx : Void*) : Nil
      @@stw_ngregs[slot] = 0
      return if uctx.null? || UCONTEXT_NGREGS <= 0
      n = UCONTEXT_NGREGS
      n = MAX_STW_GREGS if n > MAX_STW_GREGS
      i = 0
      while i < n
        @@stw_gregs[slot][i] = (uctx + UCONTEXT_GREGS_OFFSET + i * 8).as(UInt64*).value
        i += 1
      end
      @@stw_ngregs[slot] = n
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

    # Yield each GP register word saved at suspend for *id* (may be empty).
    def self.each_thread_greg(id : LibC::PthreadT, & : Void* ->) : Nil
      with_thread_gregs(id) do |gregs, n|
        j = 0
        while j < n
          yield Pointer(Void).new(gregs[j])
          j += 1
        end
      end
    end

    # Yield the raw glibc gregs snapshot for *id* (x86_64: REG_R8=0 … REG_RIP=16).
    # Used by StackMaps to resolve DWARF register locations at the suspend PC.
    def self.with_thread_gregs(id : LibC::PthreadT, & : Pointer(UInt64), Int32 ->) : Nil
      return unless @@stw_enabled && @@stw_booted
      claimed = @@stw_claimed.get(:acquire)
      i = 0
      while i < MAX_STW_SP_SLOTS
        if (claimed & (1_u64 << i)) != 0 && LibC.pthread_equal(@@stw_ids[i], id) != 0
          n = @@stw_ngregs[i]
          return if n <= 0
          # StaticArray(StaticArray) is contiguous — cast slot to UInt64*.
          yield (@@stw_gregs.to_unsafe + i).as(UInt64*), n
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
        @@stw_ngregs[i] = 0
        i += 1
      end
    end

    # Reset SP table after fork (child inherits parent bits / pthread ids).
    def self.reset_stw_after_fork : Nil
      @@stw_installed = false
      ensure_stw_table
      @@stw_claimed.set(0_u64, :release)
      i = 0
      while i < MAX_STW_SP_SLOTS
        @@stw_sps[i] = 0
        @@stw_ngregs[i] = 0
        i += 1
      end
    end

    def self.sp_from_ucontext(uctx : Void*) : UInt64
      return 0_u64 if uctx.null?
      {% if (flag?(:x86_64) || flag?(:aarch64)) && flag?(:linux) %}
        (uctx + UCONTEXT_SP_OFFSET).as(UInt64*).value
      {% else %}
        0_u64
      {% end %}
    end

    # Back-compat name.
    def self.rsp_from_ucontext(uctx : Void*) : UInt64
      sp_from_ucontext(uctx)
    end

    # Install after Crystal::System::Thread.init_suspend_resume.
    def self.install_stw_sp_capture : Nil
      {% unless flag?(:linux) && (flag?(:x86_64) || flag?(:aarch64)) %}
        return
      {% end %}
      return if @@stw_installed
      ensure_stw_table

      action = LibC::Sigaction.new
      action.sa_flags = LibC::SA_SIGINFO
      action.sa_sigaction = LibC::SigactionHandlerT.new do |_sig, _info, uctx|
        sp = Platform.sp_from_ucontext(uctx)
        Platform.record_thread_sp(LibC.pthread_self, sp, uctx) if sp != 0

        # Mirror Crystal::System::Thread suspend handler, but clear
        # `@suspended` after SIG_RESUME so start_world can confirm wake.
        thread = ::Thread.current
        thread.@suspended.set(true)

        mask = uninitialized LibC::SigsetT
        LibC.sigfillset(pointerof(mask))
        LibC.sigdelset(pointerof(mask), STW_SIG_RESUME)
        # sa_mask blocks SIG_RESUME during this handler until sigsuspend
        # atomically unblocks it — otherwise a fast resume is consumed by the
        # empty SIG_RESUME handler and sigsuspend waits forever (GCRY_STRESS).
        LibC.sigsuspend(pointerof(mask))
        thread.@suspended.set(false)
      end
      LibC.sigemptyset(pointerof(action.@sa_mask))
      # Block resume for the whole SIGPWR handler except inside sigsuspend.
      LibC.sigaddset(pointerof(action.@sa_mask), STW_SIG_RESUME)
      LibC.sigaction(STW_SIG_SUSPEND, pointerof(action), nil)
      @@stw_installed = true
    end
  end
end
