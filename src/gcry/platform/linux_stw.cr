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
    # Handler bookkeeping. A thread that reports no registers is either one the
    # handler never ran for, or one it ran for and could not record — and those
    # are different defects. Plain `UInt64`, set in `ensure_stw_table`: a class
    # variable with an initializer goes through `Crystal.once`, which is not
    # available where this runs.
    @@stw_handler_calls = uninitialized UInt64
    @@stw_sp_zero = uninitialized UInt64
    @@stw_records = uninitialized UInt64
    @@stw_booted = false
    @@stw_enabled = true
    @@stw_installed = false

    # ── The stop epoch ───────────────────────────────────────────────────────
    #
    # A suspend signal is only honoured for the stop that asked for it.
    #
    # Why this exists: `stop_world` spins `until thread.@suspended.get` for a
    # thread that never acknowledged, and six aarch64 CI jobs died at the
    # 20-minute job timeout there (reported as *cancelled*, which is why it went
    # unread for weeks). The obvious repair is the one `start_world` already
    # makes for resume — send the signal again — and without this epoch it is
    # **not safe**: `SIG_SUSPEND` is blocked for the whole handler and inside
    # `sigsuspend`, so a redundant one stays pending and is delivered *after*
    # the thread resumes, suspending it again with nobody left to wake it.
    #
    # `@@stw_epoch` is 0 when no stop is in progress and carries the stop's id
    # while one is. A sentinel rather than a parity bit on purpose: `stop_world`
    # has failure paths that leave through a `rescue`, and a counter whose
    # meaning depends on being incremented an even number of times would invert
    # — every later suspend signal dropped, which is the hang this closes, with
    # the collector now the one holding the wrong end.
    #
    # A delivery is honoured only when the epoch is non-zero and this thread has
    # not already served *that* epoch. Every other case is a duplicate, and each
    # is safe:
    #
    #   - epoch 0 — no stop is in progress; the world is running and a thread
    #     that suspended itself here would never be resumed.
    #   - already served — the collector is still inside the same stop and has
    #     the acknowledgement it asked for.
    #   - a *newer* epoch it has not served — a stale signal delivered inside
    #     the next stop. It suspends, which that stop wants anyway, and the
    #     collector's own signal then arrives as the already-served case.
    #
    # Per-thread rather than global because the state being answered is
    # per-thread: two threads can be at different points of the same stop.
    # It rides in the slot table this file already keys by `pthread_t`.
    @@stw_epoch = uninitialized Atomic(UInt64)
    @@stw_next_epoch = uninitialized UInt64
    @@stw_served = uninitialized StaticArray(UInt64, MAX_STW_SP_SLOTS)
    # Deliveries the epoch declined, split by which case they were. Both are
    # expected to be zero on a quiet run and non-zero the moment the collector
    # resends, which is what makes "the resend is safe" a reading rather than a
    # claim.
    @@stw_stale_signals = uninitialized UInt64
    @@stw_redundant_signals = uninitialized UInt64
    # `GCRY_STW_EPOCH=0`: honour every delivery, as this handler did before the
    # epoch. The red arm for `make stw-epoch` — with it the double-signal arm
    # wedges, which is the behaviour the resend would have shipped.
    #
    # `uninitialized`, and defaulted in `ensure_stw_table`, for the reason the
    # rest of this table is: a class variable with an initializer is set up
    # lazily behind `Crystal.once`, and the **first** read of this one is
    # inside the suspend handler. Written the obvious way it hung every
    # collection with four mutator threads — one thread acknowledged and the
    # rest sat in the lazy initializer, which is not async-signal-safe. The
    # arm that set the knob explicitly passed, because setting it is what
    # initialised it on a normal thread.
    @@stw_epoch_enabled = uninitialized Bool

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
      @@stw_handler_calls = 0_u64
      @@stw_sp_zero = 0_u64
      @@stw_records = 0_u64
      @@stw_epoch.set(0_u64)
      @@stw_next_epoch = 0_u64
      @@stw_stale_signals = 0_u64
      @@stw_redundant_signals = 0_u64
      @@stw_epoch_enabled = true
      i = 0
      while i < MAX_STW_SP_SLOTS
        @@stw_served[i] = 0_u64
        # The ids too, and for the same reason `clear_thread_sps` clears them:
        # a claim publishes its bit before its id, so a peer scanning the very
        # first stop must not be able to match whatever was in this static.
        clear_slot_id(i)
        i += 1
      end
      @@stw_booted = true
    end

    # The stop in progress, or 0. Read by the suspend handler on every
    # delivery, so it is one acquire load and nothing else.
    def self.stw_epoch : UInt64
      @@stw_booted ? @@stw_epoch.get(:acquire) : 0_u64
    end

    def self.stw_epoch_enabled? : Bool
      ensure_stw_table
      @@stw_epoch_enabled
    end

    # `ensure_stw_table` first, and the order matters: it defaults the flag,
    # so booting *after* this setter would reinstate the default and quietly
    # ignore the knob. Boot, then overwrite.
    def self.stw_epoch_enabled=(value : Bool) : Bool
      ensure_stw_table
      @@stw_epoch_enabled = value
    end

    def self.stw_stale_signals : UInt64
      @@stw_booted ? @@stw_stale_signals : 0_u64
    end

    def self.stw_redundant_signals : UInt64
      @@stw_booted ? @@stw_redundant_signals : 0_u64
    end

    # Called by `stop_world` **before** the first suspend signal. A signal sent
    # while the epoch is still 0 would be declined by its own handler.
    #
    # Only the collector calls this, and only with `Thread.lock` held, so the
    # id counter needs no atomic. The published value does: the handler reads
    # it from another thread.
    def self.begin_stop_epoch : UInt64
      ensure_stw_table
      e = @@stw_next_epoch &+ 1
      e = 1_u64 if e == 0 # 0 is the "no stop" sentinel, never an epoch
      @@stw_next_epoch = e
      @@stw_epoch.set(e, :release)
      e
    end

    # Called by `start_world` before the first resume, and by every path that
    # leaves `stop_world` without a stopped world. Idempotent: a stop that
    # fails twice must not leave the sentinel inverted.
    def self.end_stop_epoch : Nil
      return unless @@stw_booted
      @@stw_epoch.set(0_u64, :release)
    end

    # Async-signal-safe. Answers whether this `SIG_SUSPEND` delivery belongs to
    # a stop that is in progress and that this thread has not already served,
    # and records the SP/register snapshot when it does.
    #
    # The snapshot is deliberately **not** taken for a declined delivery: the
    # thread is about to return to what it was doing, so its SP is not a
    # stopped-world SP and writing it would hand the scan a stack bound from a
    # thread that is running.
    def self.admit_suspend_signal?(sp : UInt64, uctx : Void*) : Bool
      # An unbooted table means no stop can have been started through
      # `begin_stop_epoch`, and the flag below is `uninitialized` — reading it
      # would be reading whatever is in that static. Honour the delivery, which
      # is what this handler did before the epoch.
      return true unless @@stw_booted

      unless @@stw_epoch_enabled
        record_thread_sp(LibC.pthread_self, sp, uctx) if sp != 0
        return true
      end

      epoch = @@stw_booted ? @@stw_epoch.get(:acquire) : 0_u64
      if epoch == 0
        @@stw_stale_signals &+= 1 if @@stw_booted
        return false
      end

      slot = sp != 0 ? record_thread_sp(LibC.pthread_self, sp, uctx) : -1
      # No slot means a full table, which costs this thread its SP clamp and
      # must not also cost it the stop: fall through and suspend.
      return true if slot < 0

      if @@stw_served[slot] == epoch
        @@stw_redundant_signals &+= 1
        return false
      end
      @@stw_served[slot] = epoch
      true
    end

    # Record SP (+ GP regs) for the interrupted thread (signal-handler safe).
    # Signal-handler safe: three plain increments, no allocation, no locks.
    def self.note_stw_handler(sp : UInt64) : Nil
      ensure_stw_table
      @@stw_handler_calls &+= 1
      @@stw_sp_zero &+= 1 if sp == 0
    end

    def self.stw_handler_calls : UInt64
      @@stw_booted ? @@stw_handler_calls : 0_u64
    end

    def self.stw_sp_zero : UInt64
      @@stw_booted ? @@stw_sp_zero : 0_u64
    end

    def self.stw_records : UInt64
      @@stw_booted ? @@stw_records : 0_u64
    end

    # Returns the slot this thread occupies, or -1 when the table is full. The
    # index is what `admit_suspend_signal?` stamps its served epoch into, so
    # the two never walk the table twice for one delivery.
    def self.record_thread_sp(id : LibC::PthreadT, sp : UInt64, uctx : Void* = Pointer(Void).null) : Int32
      ensure_stw_table
      @@stw_records &+= 1
      claimed = @@stw_claimed.get(:acquire)
      i = 0
      while i < MAX_STW_SP_SLOTS
        if (claimed & (1_u64 << i)) != 0 && LibC.pthread_equal(@@stw_ids[i], id) != 0
          @@stw_sps[i] = sp
          copy_ucontext_gregs(i, uctx)
          return i
        end
        i += 1
      end
      # Claim a free slot via CAS on the bitmask.
      #
      # `Atomic#compare_and_set` returns `{old_value, success}` — a **tuple**,
      # which is always truthy, so `if @@stw_claimed.compare_and_set(…)` took
      # the success branch whether or not the exchange happened. Every thread
      # signalled in the same stop reads `claimed` before any of them writes
      # it, picks the same lowest free bit, and they all "claim" it: one slot,
      # several threads, last id written wins.
      #
      # It had been latent because the slot only carried an SP and a register
      # row — two threads sharing one meant the loser's stack was scanned from
      # the winner's SP, a missed root nobody had a reason to look for. The
      # stop epoch made it a hang instead: the second thread to arrive found
      # the first one's served stamp under its own index and declined the
      # signal, so four mutator threads on a first collection left one running
      # and the stop waiting on it forever. Found by exactly that
      # (`/proc/<pid>/task`: three in `rt_sigsuspend`, one spinning).
      loop do
        claimed = @@stw_claimed.get(:acquire)
        i = 0
        while i < MAX_STW_SP_SLOTS
          bit = 1_u64 << i
          if (claimed & bit) == 0
            _, won = @@stw_claimed.compare_and_set(claimed, claimed | bit)
            if won
              @@stw_ids[i] = id
              @@stw_sps[i] = sp
              # A slot is reused by whichever thread claims it next, so the
              # served stamp starts clean here as well as in `clear_thread_sps`
              # — otherwise a thread could inherit a predecessor's epoch and
              # decline the one signal that was meant for it.
              @@stw_served[i] = 0_u64
              copy_ucontext_gregs(i, uctx)
              return i
            end
            break # retry outer loop with fresh claimed
          end
          i += 1
        end
        return -1 if i >= MAX_STW_SP_SLOTS # table full
      end
    end

    private def self.copy_ucontext_gregs(slot : Int32, uctx : Void*) : Nil
      @@stw_ngregs[slot] = 0
      return if uctx.null? || UCONTEXT_NGREGS <= 0
      n = UCONTEXT_NGREGS
      n = MAX_STW_GREGS if n > MAX_STW_GREGS
      # Through a pointer, not `@@stw_gregs[slot][i] = …`. `StaticArray` is a
      # value type: the inner subscript returns a **copy** of the row, the
      # assignment lands in that copy, and the copy is discarded. The table
      # therefore stayed zero and `each_thread_greg` handed the mark 23 zero
      # words per thread — a register was never a root on this path, so any
      # value LLVM kept only in a callee-saved register was collected.
      #
      # Found by dumping the captured registers of every thread at the moment a
      # live object was about to be swept: all zeros, for every thread that
      # reported any (`bench/log/linux/2026-08-26-debug-build-own-stack-root/`).
      # The SP was right the whole time because it is read straight from the
      # `ucontext` by `sp_from_ucontext`, never through this table.
      row = (@@stw_gregs.to_unsafe + slot).as(UInt64*)
      i = 0
      while i < n
        row[i] = (uctx + UCONTEXT_GREGS_OFFSET + i * 8).as(UInt64*).value
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

    # Releasing a slot **must** clear its id, not just its claimed bit.
    #
    # The claim publishes the bit by CAS and writes the id afterwards, so a
    # peer scanning for its own id can see a slot that is claimed and still
    # carries whatever was in it before. Leaving last stop's ids there made
    # that "whatever" the scanner's **own** handle from the previous stop: it
    # matched, and two threads shared one slot. It cost a clobbered SP and
    # register row before the epoch — the loser's stack scanned from the
    # winner's SP — and a hang after it, because the winner's served stamp sat
    # under the loser's index and declined the signal meant for it.
    # Observed on `find_block_race --child alloc` with `GCRY_INDEX_AUDIT=1`:
    # `declined … redundant 2`, one thread never acknowledging. With the ids
    # zeroed a scanner sees either its own live slot or no match, and no
    # `pthread_t` compares equal to a cleared one.
    def self.clear_thread_sps : Nil
      return unless @@stw_booted
      @@stw_claimed.set(0_u64, :release)
      i = 0
      while i < MAX_STW_SP_SLOTS
        @@stw_sps[i] = 0
        @@stw_ngregs[i] = 0
        @@stw_served[i] = 0_u64
        clear_slot_id(i)
        i += 1
      end
    end

    # `PthreadT` is an integer alias on glibc and `Void*` on musl, so neither
    # `0` nor `.new` writes it portably. Same idiom as `Heap#@mark_pthreads`.
    private def self.clear_slot_id(i : Int32) : Nil
      zero = uninitialized LibC::PthreadT
      pointerof(zero).clear
      @@stw_ids[i] = zero
    end

    # Reset SP table after fork (child inherits parent bits / pthread ids).
    #
    # The epoch goes back to "no stop in progress" with it. A child forked by a
    # thread that was not the collector inherits whatever the parent's epoch
    # was, and the only thread that could have ended it does not exist here.
    def self.reset_stw_after_fork : Nil
      @@stw_installed = false
      ensure_stw_table
      @@stw_claimed.set(0_u64, :release)
      @@stw_epoch.set(0_u64, :release)
      i = 0
      while i < MAX_STW_SP_SLOTS
        @@stw_sps[i] = 0
        @@stw_ngregs[i] = 0
        @@stw_served[i] = 0_u64
        clear_slot_id(i)
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
        Platform.note_stw_handler(sp)

        # Every delivery is counted above; only the ones a stop in progress
        # asked for are served. See `admit_suspend_signal?` — this branch is
        # what makes `stop_world`'s resend safe, and without it a redundant
        # signal suspends a thread that nothing will resume.
        if Platform.admit_suspend_signal?(sp, uctx)
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
      end
      LibC.sigemptyset(pointerof(action.@sa_mask))
      # Block resume for the whole SIGPWR handler except inside sigsuspend.
      LibC.sigaddset(pointerof(action.@sa_mask), STW_SIG_RESUME)
      LibC.sigaction(STW_SIG_SUSPEND, pointerof(action), nil)
      @@stw_installed = true
    end
  end
end
