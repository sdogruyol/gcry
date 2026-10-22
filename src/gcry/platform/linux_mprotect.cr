# Page-granularity write barrier backends for nursery / incremental mark
# without compiler barriers.
#
# Prefer Linux soft-dirty (see linux_softdirty.cr). When unavailable, optional
# mprotect(PROT_READ) + SEGV handler marks pages dirty (Boehm-style).

require "c/sys/mman"
require "c/signal"

lib LibC
  fun sigaction(sig : Int, act : Sigaction*, oldact : Sigaction*) : Int
end

module Gcry
  module Platform
    # Barrier backend selected for nursery / incremental dirty tracking.
    enum BarrierBackend
      None
      SoftDirty
      Mprotect
    end

    # Asked, not assumed: `mprotect` requires a page-aligned address, so a
    # hardcoded 4 KiB on a larger-page host fails the call rather than the
    # alignment. See the note in `linux_softdirty.cr`.
    PAGE = begin
      sz = LibC.sysconf(LibC::SC_PAGESIZE)
      sz > 0 ? sz.to_u64 : 4096_u64
    end

    # `si_code` of a write to a mapped page whose protection forbids it. A
    # fault on an unmapped page is `SEGV_MAPERR` (1) and is never ours.
    SEGV_ACCERR = 2

    # The barrier's card state: one LibC block holding the range, a link and
    # two bitmaps, `dirty` then `protected`, `nwords` words each. Published
    # whole through `@@mp_state`, so the SEGV handler — which runs on any
    # thread, SYSMON included, while the collector swaps ranges — reads one
    # pointer and a consistent range. Not the GC heap: the handler must not
    # allocate. `next` links a state on the retired list once a swap has
    # replaced it.
    struct MprotectCards
      property base : UInt64
      property pages : Int32
      property nwords : Int32
      property next : Pointer(MprotectCards)

      def initialize(@base, @pages, @nwords, @next = Pointer(MprotectCards).null)
      end
    end

    # The collector swaps the card state (`clear_mprotect_cards`,
    # `mprotect_set_heap_range`) and protects pages under it; fault handlers
    # on every other thread read it and unprotect pages, with no lock
    # between the two, because the handler may take none. Inside a stop that
    # is safe by itself: the handler holds the stop's suspend signal off
    # (`install_mprotect_barrier`), so a stop that has stopped every thread
    # has no handler inside. But a collection whose sweep runs after the
    # world restarts — the lazy sweep, the default — re-arms the barrier
    # after that sweep with the world running (`run_collection_body`'s lazy
    # path; `abort_incremental` disarms the same way), and a handler can be
    # anywhere in its few dozen instructions when the cards and the
    # protection change under it. Until 2026-10-22 that went wrong four
    # ways, each forced red by
    # `process_spec/regression/87_mprotect_rearm_running_handler_spec.cr`:
    #
    # - The re-arm's two swaps freed the cards a running handler had read:
    #   `disarm_mprotect_barrier` retired them and `mprotect_set_heap_range`
    #   freed what had just been retired, a use-after-free in the handler.
    #   Now a retired state is freed only when no handler is inside
    #   (`@@mp_inflight`, `reclaim_mprotect_cards`).
    # - A handler that had claimed the page under the old cards made it
    #   writable after the re-arm had protected it again under new cards
    #   that called it protected and clean, so that write and every later
    #   one to the page until the next arm reached no dirty bit. Now the
    #   handler checks the generation after its `mprotect` and records the
    #   page in whatever cards replaced its own (`mprotect_recheck`).
    # - A fault taken under the old protection, whose handler read the
    #   cards only after the disarm had unprotected the page, found the page
    #   not protected and called the fault foreign: the handler uninstalled
    #   itself and handed the retried write to the previous handler
    #   (Crystal's). Harmless while the page stayed writable; a crash once
    #   the re-arm had protected it again first. Now an unclaimed protection
    #   fault is retried once before it is forwarded (`mprotect_unclaimed`).
    # - Such a fault read the new cards between the re-arm setting the
    #   page's protected bit and its `mprotect`: it claimed the page and
    #   unprotected it, then the re-arm protected it, and every later writer
    #   found the bits saying "claimed" on a read-only page and returned to
    #   fault again, until a later collection unprotected it. Now a handler
    #   that returns true has made the page writable itself.
    #
    # `bench/log/linux/2026-10-22-mprotect-card-reclaim/FINDINGS.md`.
    @@mp_state = Atomic(Pointer(MprotectCards)).new(Pointer(MprotectCards).null)
    # States a swap replaced and nothing has freed yet, linked through
    # `next`. Collector only.
    @@mp_retired = Pointer(MprotectCards).null
    # Fault handlers inside `mprotect_fault`. Raised before the handler reads
    # `@@mp_state` and lowered after its last access to what it read, so a
    # zero read *after* a swap proves that no handler holds the state the
    # swap replaced: one that raised it later reads the new pointer (all
    # sequentially consistent). Two atomics per fault, against a signal
    # delivery and an `mprotect` call.
    @@mp_inflight = Atomic(Int32).new(0)
    # Bumped after every swap and every dirty-bit clear, each of which comes
    # before the collector protects pages under new or cleared cards. See
    # `mprotect_recheck`.
    @@mp_gen = Atomic(UInt64).new(0_u64)
    # Retired states freed while a handler was inside. Only the control arm
    # (`mprotect_defer_free = false`) can count one. Collector only.
    @@mp_unsafe_frees = 0_u64
    # This thread's last unclaimed protection fault, and the generation it
    # was taken in (`mprotect_unclaimed`). Literal initializers: read in the
    # handler, so no `__crystal_once`.
    @[ThreadLocal]
    @@mp_unclaimed_addr : UInt64 = 0_u64
    @[ThreadLocal]
    @@mp_unclaimed_gen : UInt64 = 0_u64
    @@mp_installed = false
    @@mp_enabled = false
    @@mp_old_sa = uninitialized LibC::Sigaction
    # Atomic: SEGV handler mutates; plain UInt64 is register-cached under
    # --release so the mutator never observes the increment (false-pending
    # barrier_spec on WSL/Linux release builds).
    @@mp_hits = Atomic(UInt64).new(0_u64)

    def self.mprotect_barrier_enabled? : Bool
      @@mp_enabled
    end

    def self.mprotect_hits : UInt64
      @@mp_hits.get
    end

    # Research only: retired card states not yet freed.
    def self.mprotect_retired_count : Int32
      n = 0
      st = @@mp_retired
      until st.null?
        n += 1
        st = st.value.next
      end
      n
    end

    # Research only: see `@@mp_unsafe_frees`.
    def self.mprotect_unsafe_frees : UInt64
      @@mp_unsafe_frees
    end

    # Research only: see `@@mp_gen`. A test reads it to tell whether a
    # re-arm happened after a point.
    def self.mprotect_generation : UInt64
      @@mp_gen.get
    end

    # Research only: called by `mprotect_fault`, in the SEGV handler, with
    # the faulting address, after the card state is read and before it or
    # the page is touched. Must not allocate. A hook that parks the handler
    # there puts a stop in the window
    # (`process_spec/regression/83_mprotect_fault_frozen_handler_spec.cr`),
    # or a re-arm with the world running (`87_mprotect_rearm_running_handler_spec.cr`).
    class_property mprotect_fault_hook : Proc(UInt64, Nil)? = nil
    # Research only: the same, in the handler before the generation and the
    # card state are read — where a handler stands whose fault was taken
    # under protection a re-arm is about to replace (regression 87).
    class_property mprotect_entry_hook : Proc(UInt64, Nil)? = nil
    # Research only: the same, after the handler has claimed the page in the
    # cards and before its `mprotect` makes the page writable (regression 87).
    class_property mprotect_claim_hook : Proc(UInt64, Nil)? = nil
    # Research only: called by `mprotect_protect_range`, on the collector,
    # with the page range, after the protected bits are set and before the
    # pages are protected (regression 87).
    class_property mprotect_protect_hook : Proc(UInt64, UInt64, Nil)? = nil
    # Research only: false installs the handler with the stop's suspend
    # signal deliverable inside it, the code before 2026-10-22 — the control
    # arm of regression 83. Read when the handler is installed.
    class_property mprotect_block_suspend : Bool = true
    # Research only, the control arms of regression 87: each false restores
    # the code before 2026-10-22 for one of the four hazards described above
    # `@@mp_state`. False frees a retired state at the next swap whether or
    # not a handler is inside.
    class_property mprotect_defer_free : Bool = true
    # False skips the generation check after the handler's `mprotect`.
    class_property mprotect_revalidate : Bool = true
    # False forwards an unclaimed protection fault at once.
    class_property mprotect_retry_unclaimed : Bool = true
    # False lets a handler that finds the page already claimed return without
    # making it writable, trusting the claimer to.
    class_property mprotect_claim_unprotects : Bool = true

    # Install SEGV handler that re-enables write + marks page dirty.
    # Faults the barrier did not cause are forwarded to the previous handler.
    def self.install_mprotect_barrier : Bool
      {% unless flag?(:linux) %}
        return false
      {% end %}
      return true if @@mp_installed

      action = LibC::Sigaction.new
      action.sa_flags = LibC::SA_SIGINFO
      action.sa_sigaction = LibC::SigactionHandlerT.new do |_sig, info, _uctx|
        addr = info.value.si_addr.address
        code = info.value.si_code
        unless Platform.mprotect_fault(addr, code)
          Platform.mprotect_unclaimed(addr, code)
        end
      end
      LibC.sigemptyset(pointerof(action.@sa_mask))
      # The stop's suspend signal waits until the handler returns. The
      # handler reads the card state (`@@mp_state`), then sets the page's
      # dirty bit in it and unprotects the page. A stop that froze it in
      # between re-armed the barrier inside the stop
      # (`arm_page_barrier_after_major` / `_after_collect`): it freed that
      # state — `disarm_mprotect_barrier` retired it and
      # `mprotect_set_heap_range` freed what had just been retired — and
      # protected the page again under fresh cards with its dirty bit clear.
      # The handler resumed into freed memory, then made the page writable
      # behind the new cards' back, so the write it retried, and every one
      # after it until the next arm, reached no dirty bit: an old→young or
      # an incremental edge the barrier exists to report, lost. Bounded:
      # the handler takes no lock and makes one `mprotect` call, so the stop
      # waits that long. `bench/log/linux/2026-10-22-in-stop-sweep-audit/`.
      # A re-arm with the world running meets a handler the same way and
      # cannot wait for it; that is answered by the scheme described above
      # `@@mp_state`, which would also answer a frozen handler, but a stop
      # that never has a handler inside stays the simpler guarantee.
      LibC.sigaddset(pointerof(action.@sa_mask), STW_SIG_SUSPEND) if @@mprotect_block_suspend
      if LibC.sigaction(LibC::SIGSEGV, pointerof(action), pointerof(@@mp_old_sa)) != 0
        return false
      end
      @@mp_installed = true
      @@mp_enabled = true
      true
    end

    def self.disable_mprotect_barrier : Nil
      return unless @@mp_installed
      LibC.sigaction(LibC::SIGSEGV, pointerof(@@mp_old_sa), nil)
      @@mp_installed = false
      @@mp_enabled = false
      clear_mprotect_cards
    end

    # In a forked child only the forking thread survives, so no handler is
    # inside: a count another thread left raised would hold every later
    # free back for good.
    def self.mprotect_after_fork : Nil
      @@mp_inflight.set(0)
    end

    # Register a contiguous heap range for card tracking (replaces prior range).
    #
    # The caller unprotects every page of the old range first
    # (`Heap#disarm_mprotect_barrier`): a page left read-only under a range
    # that no longer covers it faults with nothing to claim it.
    def self.mprotect_set_heap_range(low : UInt64, high : UInt64) : Nil
      clear_mprotect_cards
      return if high <= low
      page_lo = low & ~(PAGE - 1)
      page_hi = (high + PAGE - 1) & ~(PAGE - 1)
      pages = ((page_hi - page_lo) // PAGE).to_i32
      return if pages <= 0 || pages > 16_777_216 # sanity

      nwords = (pages + 63) // 64
      bytes = sizeof(MprotectCards).to_u64 + (nwords * 2 * 8).to_u64
      ptr = LibC.malloc(LibC::SizeT.new(bytes)).as(MprotectCards*)
      return if ptr.null?
      ptr.as(UInt8*).clear(bytes)
      ptr.value = MprotectCards.new(page_lo, pages, nwords)
      @@mp_state.set(ptr)
    end

    # Unpublish the card state and retire it. Collector only. What is
    # retired is freed once no handler is inside (`reclaim_mprotect_cards`).
    def self.clear_mprotect_cards : Nil
      old = @@mp_state.swap(Pointer(MprotectCards).null)
      # After the swap, not before: a handler that reads the generation
      # after this bump reads the card state after the swap as well.
      @@mp_gen.add(1_u64)
      if @@mprotect_defer_free
        retire_mprotect_cards(old)
        reclaim_mprotect_cards
      else
        # The code before 2026-10-22: free what the previous swap retired
        # and keep this one. A re-arm swaps twice, so its second swap freed
        # the cards its first had just retired, under any handler inside.
        @@mp_unsafe_frees &+= 1 if !@@mp_retired.null? && @@mp_inflight.get != 0
        free_retired_mprotect_cards
        retire_mprotect_cards(old)
      end
    end

    # Free every retired card state if no fault handler is inside. Called
    # after a swap, so a zero count proves no handler holds one
    # (`@@mp_inflight`). A handler is inside for a few dozen instructions and
    # one `mprotect`, so a later swap — a collection makes at least one —
    # finds the count at zero. What the last swap before the barrier is
    # taken down for good could not free stays allocated: one card state,
    # two bits per page of the heap span.
    def self.reclaim_mprotect_cards : Nil
      return if @@mp_retired.null?
      return unless @@mp_inflight.get == 0
      free_retired_mprotect_cards
    end

    private def self.retire_mprotect_cards(st : MprotectCards*) : Nil
      return if st.null?
      st.value.next = @@mp_retired
      @@mp_retired = st
    end

    private def self.free_retired_mprotect_cards : Nil
      st = @@mp_retired
      @@mp_retired = Pointer(MprotectCards).null
      until st.null?
        succ = st.value.next
        LibC.free(st.as(Void*))
        st = succ
      end
    end

    private def self.dirty_words(st : MprotectCards*) : UInt64*
      (st + 1).as(UInt64*)
    end

    private def self.protected_words(st : MprotectCards*) : UInt64*
      dirty_words(st) + st.value.nwords
    end

    # Set or clear the protected bit of every whole page in [page_lo, page_hi).
    private def self.note_protected(page_lo : UInt64, page_hi : UInt64, value : Bool) : Nil
      st = @@mp_state.get
      return if st.null?
      base = st.value.base
      limit = base + st.value.pages.to_u64 * PAGE
      lo = page_lo < base ? base : page_lo
      hi = page_hi > limit ? limit : page_hi
      return if hi <= lo
      words = protected_words(st)
      idx = ((lo - base) // PAGE).to_i32
      last = ((hi - base) // PAGE).to_i32
      while idx < last
        word = words + (idx >> 6)
        mask = 1_u64 << (idx & 63)
        if value
          Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Or, word, mask, LLVM::AtomicOrdering::SequentiallyConsistent, false)
        else
          Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::And, word, ~mask, LLVM::AtomicOrdering::SequentiallyConsistent, false)
        end
        idx += 1
      end
    end

    # Protect old (non-nursery) size-class / large chunk pages as read-only.
    # The protected bits are set before the pages are: a write in between
    # faults onto a page the handler already owns.
    def self.mprotect_protect_range(low : UInt64, high : UInt64) : Nil
      return unless @@mp_enabled
      return if high <= low
      page_lo = (low + PAGE - 1) & ~(PAGE - 1)
      page_hi = high & ~(PAGE - 1)
      return if page_hi <= page_lo
      note_protected(page_lo, page_hi, true)
      if hook = @@mprotect_protect_hook
        hook.call(page_lo, page_hi)
      end
      LibC.mprotect(Pointer(Void).new(page_lo), LibC::SizeT.new(page_hi - page_lo), LibC::PROT_READ)
    end

    def self.mprotect_unprotect_range(low : UInt64, high : UInt64) : Nil
      return if high <= low
      page_lo = low & ~(PAGE - 1)
      page_hi = (high + PAGE - 1) & ~(PAGE - 1)
      return if page_hi <= page_lo
      LibC.mprotect(Pointer(Void).new(page_lo), LibC::SizeT.new(page_hi - page_lo),
        LibC::PROT_READ | LibC::PROT_WRITE)
      note_protected(page_lo, page_hi, false)
    end

    # Called from SEGV handler. True only for a write the barrier caused: a
    # protection fault (`SEGV_ACCERR`) on a page it protected, or on one
    # another fault has already claimed (its dirty bit is set). Anything
    # else — an unmapped page (a freed chunk), a `PROT_NONE` guard page
    # inside the heap span — is not claimed (`mprotect_unclaimed`). Until
    # 2026-10-05 every address in the range was claimed: a read of an
    # unmapped chunk "unprotected" it, the `mprotect` failed unseen, and the
    # access faulted forever (`make nursery-tlab-smoke`, 6 of 8 runs hung).
    #
    # Counted in `@@mp_inflight` for as long as it may touch the card state
    # it read: see `reclaim_mprotect_cards`.
    def self.mprotect_fault(addr : UInt64, code : Int32 = SEGV_ACCERR) : Bool
      return false unless code == SEGV_ACCERR
      @@mp_inflight.add(1)
      claimed = mprotect_claim(addr)
      @@mp_inflight.sub(1)
      claimed
    end

    private def self.mprotect_claim(addr : UInt64) : Bool
      if hook = @@mprotect_entry_hook
        hook.call(addr)
      end
      # Before the card state, not after: see `mprotect_recheck`.
      gen = @@mp_gen.get
      st = @@mp_state.get
      return false if st.null?
      base = st.value.base
      return false if addr < base
      # The distance is checked before it is narrowed: `to_i32` of an
      # address far above the range would raise, here in a signal handler.
      offset = addr - base
      return false if offset >= st.value.pages.to_u64 * PAGE
      idx = (offset // PAGE).to_i32
      if hook = @@mprotect_fault_hook
        hook.call(addr)
      end

      word = idx >> 6
      mask = 1_u64 << (idx & 63)
      prot = protected_words(st) + word
      dirty = dirty_words(st) + word
      if (Atomic::Ops.load(prot, LLVM::AtomicOrdering::SequentiallyConsistent, true) & mask) == 0
        # Not protected under these cards. Another fault took this page
        # first if its dirty bit is set (it sets dirty before it clears the
        # protected bit); otherwise the fault is not ours, or was taken
        # under protection a disarm has since lifted (`mprotect_unclaimed`).
        return false if (Atomic::Ops.load(dirty, LLVM::AtomicOrdering::SequentiallyConsistent, true) & mask) == 0
        # The page is recorded; make sure it is writable rather than trust
        # the claimer to. Its `mprotect` may have landed *before* a re-arm's
        # (a claim between the re-arm's protected bit and its `mprotect`),
        # and then nothing would ever unprotect the page: every write to it
        # would fault back here until the next collection.
        return true unless @@mprotect_claim_unprotects
      else
        # Dirty first, then the protected bit: see the branch above.
        Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Or, dirty, mask, LLVM::AtomicOrdering::SequentiallyConsistent, false)
        was = Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::And, prot, ~mask, LLVM::AtomicOrdering::SequentiallyConsistent, false)
        if (was & mask) == 0
          # Lost the race between the load and the clear. The winner
          # unprotects too; so does this, for the reason above.
          return true unless @@mprotect_claim_unprotects
        else
          @@mp_hits.add(1_u64)
        end
      end
      if hook = @@mprotect_claim_hook
        hook.call(addr)
      end

      page = base + idx.to_u64 * PAGE
      return false unless LibC.mprotect(Pointer(Void).new(page), LibC::SizeT.new(PAGE),
                            LibC::PROT_READ | LibC::PROT_WRITE) == 0
      mprotect_recheck(gen, page) if @@mprotect_revalidate
      true
    end

    # After the handler's `mprotect` made *page* writable: if the collector
    # has swapped or cleared the cards since the handler read the generation,
    # it may have protected the page again first, under cards that call it
    # protected and clean — and the page is writable now. Record it in the
    # current cards, so that write and the ones after it are seen. A swap or
    # clear after this check comes before the collector's next protection of
    # the page (it bumps the generation first), which then lands after this
    # handler's `mprotect` and leaves the page read-only. Reading the
    # generation before the card state is what makes a stale state imply a
    # changed generation: the collector bumps it after the swap.
    #
    # The current cards cannot be freed under this read: the handler is
    # still counted in `@@mp_inflight`.
    private def self.mprotect_recheck(gen : UInt64, page : UInt64) : Nil
      return if @@mp_gen.get == gen
      cur = @@mp_state.get
      return if cur.null?
      base = cur.value.base
      return if page < base
      offset = page - base
      return if offset >= cur.value.pages.to_u64 * PAGE
      idx = (offset // PAGE).to_i32
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Or, dirty_words(cur) + (idx >> 6),
        1_u64 << (idx & 63), LLVM::AtomicOrdering::SequentiallyConsistent, false)
    end

    # Called from the SEGV handler for a fault `mprotect_fault` did not
    # claim. A protection fault is retried once first: one taken under
    # protection a disarm has lifted since — the handler read the cards after
    # the page was unprotected — succeeds on the retry, or faults onto
    # whatever protection a re-arm put back, which is claimable. Forwarding
    # it instead uninstalled the barrier with the re-arm's pages protected,
    # and the retried write went to the previous handler. The same fault
    # again, at the same address in the same generation, is not the
    # barrier's: the previous action is restored and the retry is handled
    # normally. Costs a foreign protection fault one extra delivery.
    def self.mprotect_unclaimed(addr : UInt64, code : Int32) : Nil
      if code == SEGV_ACCERR && @@mprotect_retry_unclaimed
        gen = @@mp_gen.get
        unless addr == @@mp_unclaimed_addr && gen == @@mp_unclaimed_gen
          @@mp_unclaimed_addr = addr
          @@mp_unclaimed_gen = gen
          return
        end
      end
      @@mp_unclaimed_addr = 0_u64
      # Not our RO page — restore previous action so the retried fault is handled normally.
      LibC.sigaction(LibC::SIGSEGV, pointerof(@@mp_old_sa), nil)
      @@mp_installed = false
      @@mp_enabled = false
    end

    def self.each_mprotect_dirty_page(& : UInt64 ->) : Nil
      st = @@mp_state.get
      return if st.null?
      words = dirty_words(st)
      i = 0
      while i < st.value.pages
        if ((words + (i >> 6)).value & (1_u64 << (i & 63))) != 0
          yield st.value.base + i.to_u64 * PAGE
        end
        i += 1
      end
    end

    # Both callers protect pages again right after (`arm_mprotect_on_old_chunks`,
    # `scan_mprotect_pages`), so the generation moves: see `mprotect_recheck`.
    def self.clear_mprotect_dirty_bits : Nil
      st = @@mp_state.get
      return if st.null?
      dirty_words(st).as(UInt8*).clear(st.value.nwords.to_u64 * 8)
      @@mp_gen.add(1_u64)
    end

    def self.count_mprotect_dirty_pages : {UInt64, UInt64}
      st = @@mp_state.get
      return {0_u64, 0_u64} if st.null?
      words = dirty_words(st)
      dirty = 0_u64
      i = 0
      while i < st.value.nwords
        dirty &+= (words + i).value.popcount.to_u64
        i += 1
      end
      {dirty, st.value.pages.to_u64}
    end
  end
end
