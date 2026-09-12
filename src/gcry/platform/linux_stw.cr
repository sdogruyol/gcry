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

    # Program counter and frame pointer in the same ucontext, for the crash
    # report's writer-frame walk (`SegvReport`). Derived from the layout above
    # rather than from a second source: x86_64 `gregs` is indexed by the
    # `REG_*` enum, so RBP is `[10]` and RIP is `[16]`, i.e. 40 + 80 and
    # 40 + 128. aarch64's `sigcontext` is
    # `{fault_address, regs[31], sp, pc, pstate}` from 176, so x29 (fp) is
    # `regs[29]` at 184 + 232, and pc follows sp: 432 + 8.
    {% if flag?(:x86_64) %}
      UCONTEXT_PC_OFFSET = 168
      UCONTEXT_FP_OFFSET = 120
    {% elsif flag?(:aarch64) %}
      UCONTEXT_PC_OFFSET = 440
      UCONTEXT_FP_OFFSET = 416
      # x30, the return address of the faulting frame when it made no frame
      # record of its own — a leaf store faulting is exactly that case.
      UCONTEXT_LR_OFFSET = 424
    {% else %}
      UCONTEXT_PC_OFFSET = 0
      UCONTEXT_FP_OFFSET = 0
    {% end %}

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

    # ── The acknowledgement ──────────────────────────────────────────────────
    #
    # A suspended thread says so here, not in `Thread#@suspended`, and the
    # reason is that the handler must not touch Crystal at all.
    #
    # `Thread#start` publishes before it sets its own TLS:
    #
    #     Thread.threads.push(self)   # on the list — `stop_world` signals it
    #     Thread.current = self       # TLS only now
    #
    # A thread signalled between those two lines has no `Thread.current`, and
    # Crystal's accessor **creates one** when the key is unset
    # (`crystal/system/unix/pthread.cr`: `self.current_thread = ::Thread.new`).
    # That constructor allocates a `Fiber`, allocates a `Thread`, and pushes
    # onto `Thread.threads` — taking the list mutex the collector holds for
    # the whole stop. Inside a signal handler, with the world stopping: the
    # handler blocks on the collector's lock and the collector waits for the
    # acknowledgement that handler was about to give. Neither moves again.
    #
    # So the ack lives in this table, the collector reserves each thread's
    # slot *before* it signals anyone, and the handler writes one plain bool.
    # `stw_no_tls_entries` counts the deliveries that found no Crystal TLS —
    # the window above, measured rather than argued.
    @@stw_acked = uninitialized StaticArray(Bool, MAX_STW_SP_SLOTS)
    @@stw_no_tls_entries = uninitialized UInt64
    # Deliveries with neither a slot nor a `Thread` to answer through. The
    # thread declines to suspend rather than freezing with no way to say so:
    # a stop that waits is recoverable and reported, one that suspends a
    # thread nobody can see acknowledged is not.
    @@stw_ack_unavailable = uninitialized UInt64
    # `GCRY_STW_ACK_VIA_THREAD=1`: acknowledge through `Thread#@suspended` as
    # this handler did before the table, `::Thread.current` and all. The
    # control arm for the window above — it is the code that allocates.
    @@stw_ack_via_thread = uninitialized Bool

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
      @@stw_no_tls_entries = 0_u64
      @@stw_ack_unavailable = 0_u64
      @@stw_ack_via_thread = false
      i = 0
      while i < MAX_STW_SP_SLOTS
        @@stw_served[i] = 0_u64
        @@stw_acked[i] = false
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

    def self.stw_ack_via_thread? : Bool
      ensure_stw_table
      @@stw_ack_via_thread
    end

    def self.stw_ack_via_thread=(value : Bool) : Bool
      ensure_stw_table
      @@stw_ack_via_thread = value
    end

    # Suspend deliveries that arrived on a thread with no `Thread.current`.
    # Non-zero means the birth window above is being hit, i.e. the pre-table
    # handler would have allocated a `Thread` and taken `Thread.lock` from
    # inside a signal handler with the world stopping.
    def self.stw_no_tls_entries : UInt64
      @@stw_booted ? @@stw_no_tls_entries : 0_u64
    end

    # Deliveries that could answer through neither route and declined to
    # suspend. Only reachable with more than `MAX_STW_SP_SLOTS` threads *and*
    # no TLS on the one that misses out.
    def self.stw_ack_unavailable : UInt64
      @@stw_booted ? @@stw_ack_unavailable : 0_u64
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

    # Returned by `admit_suspend_signal` when the delivery does not belong to
    # a stop this thread still owes an acknowledgement for.
    SUSPEND_DECLINED = -1
    # Admitted, but with no slot to answer through: the table is full.
    SUSPEND_NO_SLOT = -2

    # Async-signal-safe. Answers whether this `SIG_SUSPEND` delivery belongs to
    # a stop that is in progress and that this thread has not already served,
    # and records the SP/register snapshot when it does. The return value is
    # the slot to acknowledge in, so the handler never walks the table twice.
    #
    # The snapshot is deliberately **not** taken for a declined delivery: the
    # thread is about to return to what it was doing, so its SP is not a
    # stopped-world SP and writing it would hand the scan a stack bound from a
    # thread that is running.
    def self.admit_suspend_signal(sp : UInt64, uctx : Void*) : Int32
      # An unbooted table means no stop can have been started through
      # `begin_stop_epoch`, and the flags are `uninitialized` — reading them
      # would be reading whatever is in those statics. Honour the delivery,
      # which is what this handler did before the epoch.
      return SUSPEND_NO_SLOT unless @@stw_booted

      slot = record_thread_sp(LibC.pthread_self, sp, uctx)

      unless @@stw_epoch_enabled
        return slot < 0 ? SUSPEND_NO_SLOT : slot
      end

      epoch = @@stw_epoch.get(:acquire)
      if epoch == 0
        @@stw_stale_signals &+= 1
        return SUSPEND_DECLINED
      end

      # No slot means a full table, which costs this thread its SP clamp and
      # must not also cost it the stop: admit, and let the handler find some
      # other way to say so.
      return SUSPEND_NO_SLOT if slot < 0

      if @@stw_served[slot] == epoch
        @@stw_redundant_signals &+= 1
        return SUSPEND_DECLINED
      end
      @@stw_served[slot] = epoch
      slot
    end

    # Called by the collector, under `Thread.lock`, **before** the first
    # suspend signal goes out. Claiming here rather than from the handler is
    # what lets the wait loop spin on one array load instead of a 64-slot scan
    # per iteration, and it moves the claim off the concurrent path entirely:
    # by the time any handler runs, every slot it could want already exists.
    def self.reserve_suspend_slot(id : LibC::PthreadT) : Int32
      slot = slot_for(id)
      return slot if slot < 0
      # A slot held over from the last stop keeps its SP and registers until
      # its owner is suspended again; clear them here so a thread that is
      # never suspended this stop cannot be scanned from a stale reading.
      @@stw_sps[slot] = 0_u64
      @@stw_ngregs[slot] = 0
      @@stw_acked[slot] = false
      slot
    end

    # The slot *id* occupies, or -1. One scan, called once per thread per
    # stop — never from the spin.
    def self.suspend_slot_of(id : LibC::PthreadT) : Int32
      return -1 unless @@stw_booted
      claimed = @@stw_claimed.get(:acquire)
      i = 0
      while i < MAX_STW_SP_SLOTS
        return i if (claimed & (1_u64 << i)) != 0 && LibC.pthread_equal(@@stw_ids[i], id) != 0
        i += 1
      end
      -1
    end

    # One plain load. This is the collector's spin predicate.
    def self.suspend_acked?(slot : Int32) : Bool
      slot >= 0 && @@stw_acked[slot]
    end

    def self.set_suspend_ack(slot : Int32, value : Bool) : Nil
      @@stw_acked[slot] = value if slot >= 0
    end

    def self.note_no_tls_entry : Nil
      @@stw_no_tls_entries &+= 1 if @@stw_booted
    end

    def self.note_ack_unavailable : Nil
      @@stw_ack_unavailable &+= 1 if @@stw_booted
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
    # index is what `admit_suspend_signal` stamps its served epoch into and
    # what the handler acknowledges in, so nothing walks the table twice for
    # one delivery.
    def self.record_thread_sp(id : LibC::PthreadT, sp : UInt64, uctx : Void* = Pointer(Void).null) : Int32
      @@stw_records &+= 1 if @@stw_booted
      slot = slot_for(id)
      return -1 if slot < 0
      @@stw_sps[slot] = sp
      copy_ucontext_gregs(slot, uctx)
      slot
    end

    # Find this thread's slot, claiming a free one if it has none.
    private def self.slot_for(id : LibC::PthreadT) : Int32
      ensure_stw_table
      claimed = @@stw_claimed.get(:acquire)
      i = 0
      while i < MAX_STW_SP_SLOTS
        return i if (claimed & (1_u64 << i)) != 0 && LibC.pthread_equal(@@stw_ids[i], id) != 0
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
      #
      # The collector now reserves every slot before it signals anyone, so on
      # the shipped path this loop runs once per thread on a quiet thread and
      # never concurrently. The CAS stays because nothing structurally
      # prevents a handler from arriving first.
      loop do
        claimed = @@stw_claimed.get(:acquire)
        i = 0
        while i < MAX_STW_SP_SLOTS
          bit = 1_u64 << i
          if (claimed & bit) == 0
            _, won = @@stw_claimed.compare_and_set(claimed, claimed | bit)
            if won
              @@stw_ids[i] = id
              @@stw_sps[i] = 0_u64
              @@stw_ngregs[i] = 0
              # A slot is reused by whichever thread claims it next, so the
              # served stamp and the acknowledgement start clean here as well
              # as in `clear_thread_sps` — otherwise a thread could inherit a
              # predecessor's epoch and decline the signal meant for it, or
              # inherit an acknowledgement it never gave.
              @@stw_served[i] = 0_u64
              @@stw_acked[i] = false
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
    # Retained copy of the last stop's SP table, for the post-STW section.
    #
    # `clear_thread_sps` runs at resume, so by the time the after-world sweep
    # releases anything there is no record of what the mark phase read. That is
    # the one thing a release-time diagnostic needs: a word pointing at a
    # released block matters only if it sits in `[recorded SP, bottom)`, and
    # every other hit is dead stack space the collector is right to ignore
    # (`GCRY_RELEASE_HOLDERS`). Copied rather than kept live, because the live
    # table has to read zero before the next stop claims slots in it.
    @@last_stop_ids = uninitialized StaticArray(LibC::PthreadT, MAX_STW_SP_SLOTS)
    @@last_stop_sps = uninitialized StaticArray(UInt64, MAX_STW_SP_SLOTS)
    @@last_stop_claimed = 0_u64

    # The SP this thread was stopped at during the most recent stop, or nil.
    # Valid through the post-STW section; after that it describes a stop that
    # has since been superseded.
    def self.last_stop_sp(id : LibC::PthreadT) : Void*?
      return nil unless @@stw_booted
      claimed = @@last_stop_claimed
      i = 0
      while i < MAX_STW_SP_SLOTS
        if (claimed & (1_u64 << i)) != 0 && LibC.pthread_equal(@@last_stop_ids[i], id) != 0
          sp = @@last_stop_sps[i]
          return nil if sp == 0
          return Pointer(Void).new(sp)
        end
        i += 1
      end
      nil
    end

    def self.clear_thread_sps : Nil
      return unless @@stw_booted
      @@last_stop_claimed = @@stw_claimed.get(:acquire)
      i = 0
      while i < MAX_STW_SP_SLOTS
        @@last_stop_ids[i] = @@stw_ids[i]
        @@last_stop_sps[i] = @@stw_sps[i]
        i += 1
      end
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
        # asked for are served. See `admit_suspend_signal` — that check is
        # what makes `stop_world`'s resend safe, and without it a redundant
        # signal suspends a thread that nothing will resume.
        slot = Platform.admit_suspend_signal(sp, uctx)
        unless slot == Platform::SUSPEND_DECLINED
          # Whether this thread has a `Thread` object yet, asked with the
          # accessor that does **not** create one.
          #
          # `::Thread.current` creates on a miss: a `Fiber`, a `Thread`, and
          # a push onto `Thread.threads`, which takes the list mutex the
          # collector holds for the whole stop. From a signal handler that is
          # an allocation with the world stopping, and a deadlock against the
          # collector waiting for this very acknowledgement. The window is
          # real rather than argued: `Thread#start` pushes itself onto the
          # list *before* it sets its TLS, so a thread can be on the list —
          # hence signalled — with no `Thread.current` yet.
          published = ::Thread.current?
          Platform.note_no_tls_entry if published.nil?

          # Where the acknowledgement goes, in order of preference:
          #   the reserved slot — no Crystal at all, which is the point;
          #   `Thread#@suspended` — only if the table was full, and only for
          #     a thread that already has one;
          #   nowhere — decline to suspend rather than freeze with no way to
          #     say so. The collector then reports and resends; a thread
          #     frozen unacknowledgeably is a stop that never ends.
          ack_slot = -1
          ack_thread = nil.as(::Thread?)
          if Platform.stw_ack_via_thread?
            # `GCRY_STW_ACK_VIA_THREAD=1` — the pre-table line, verbatim,
            # creating accessor and all. `make stw-ack-window` needs it to
            # wedge on a thread with no TLS, or "the table fixed something"
            # is a claim with no control.
            ack_thread = ::Thread.current
          elsif slot >= 0
            ack_slot = slot
          elsif published
            ack_thread = published
          end

          if ack_slot < 0 && ack_thread.nil?
            Platform.note_ack_unavailable
          else
            Platform.set_suspend_ack(ack_slot, true)
            ack_thread.@suspended.set(true) if ack_thread

            mask = uninitialized LibC::SigsetT
            LibC.sigfillset(pointerof(mask))
            LibC.sigdelset(pointerof(mask), STW_SIG_RESUME)
            # sa_mask blocks SIG_RESUME during this handler until sigsuspend
            # atomically unblocks it — otherwise a fast resume is consumed by
            # the empty SIG_RESUME handler and sigsuspend waits forever
            # (GCRY_STRESS).
            LibC.sigsuspend(pointerof(mask))

            Platform.set_suspend_ack(ack_slot, false)
            ack_thread.@suspended.set(false) if ack_thread
          end
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
