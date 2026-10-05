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

    # The barrier's card state: one LibC block holding the range and two
    # bitmaps, `dirty` then `protected`, `nwords` words each. Published whole
    # through `@@mp_state`, so the SEGV handler — which runs on any thread,
    # SYSMON included, while the collector swaps ranges — reads one pointer
    # and a consistent range. Not the GC heap: the handler must not allocate.
    struct MprotectCards
      property base : UInt64
      property pages : Int32
      property nwords : Int32

      def initialize(@base, @pages, @nwords)
      end
    end

    @@mp_state = Atomic(Pointer(MprotectCards)).new(Pointer(MprotectCards).null)
    # The state the last swap replaced. Freed at the *next* swap, not this
    # one: a handler that loaded it just before the swap may still be reading
    # it, and a whole collection separates two swaps.
    @@mp_retired = Pointer(MprotectCards).null
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
        unless Platform.mprotect_fault(addr, info.value.si_code)
          # Not our RO page — restore previous action so the retried fault is handled normally.
          LibC.sigaction(LibC::SIGSEGV, pointerof(@@mp_old_sa), nil)
          @@mp_installed = false
          @@mp_enabled = false
        end
      end
      LibC.sigemptyset(pointerof(action.@sa_mask))
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

    def self.clear_mprotect_cards : Nil
      old = @@mp_state.swap(Pointer(MprotectCards).null)
      LibC.free(@@mp_retired.as(Void*)) unless @@mp_retired.null?
      @@mp_retired = old
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
    # protection fault (`SEGV_ACCERR`) on a page it protected, or on one a
    # racing thread has just unprotected (its dirty bit is set and the retry
    # will succeed). Anything else — an unmapped page (a freed chunk), a
    # `PROT_NONE` guard page inside the heap span — goes to the previous
    # handler. Until 2026-10-05 every address in the range was claimed: a read
    # of an unmapped chunk "unprotected" it, the `mprotect` failed unseen, and
    # the access faulted forever (`make nursery-tlab-smoke`, 6 of 8 runs hung).
    def self.mprotect_fault(addr : UInt64, code : Int32 = SEGV_ACCERR) : Bool
      return false unless code == SEGV_ACCERR
      st = @@mp_state.get
      return false if st.null?
      base = st.value.base
      return false if addr < base

      idx = ((addr - base) // PAGE).to_i32
      return false if idx < 0 || idx >= st.value.pages

      word = idx >> 6
      mask = 1_u64 << (idx & 63)
      prot = protected_words(st) + word
      dirty = dirty_words(st) + word
      if (Atomic::Ops.load(prot, LLVM::AtomicOrdering::SequentiallyConsistent, true) & mask) == 0
        # Another thread took this page's fault first. It set dirty before it
        # cleared the protected bit, so a set bit means the page is ours and
        # the retry succeeds once its `mprotect` lands.
        return (Atomic::Ops.load(dirty, LLVM::AtomicOrdering::SequentiallyConsistent, true) & mask) != 0
      end
      # Dirty first, then the protected bit: see the branch above.
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Or, dirty, mask, LLVM::AtomicOrdering::SequentiallyConsistent, false)
      was = Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::And, prot, ~mask, LLVM::AtomicOrdering::SequentiallyConsistent, false)
      # Lost the race between the load and the clear: the winner unprotects.
      return true if (was & mask) == 0
      @@mp_hits.add(1_u64)

      page = base + idx.to_u64 * PAGE
      LibC.mprotect(Pointer(Void).new(page), LibC::SizeT.new(PAGE),
        LibC::PROT_READ | LibC::PROT_WRITE) == 0
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

    def self.clear_mprotect_dirty_bits : Nil
      st = @@mp_state.get
      return if st.null?
      dirty_words(st).as(UInt8*).clear(st.value.nwords.to_u64 * 8)
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
