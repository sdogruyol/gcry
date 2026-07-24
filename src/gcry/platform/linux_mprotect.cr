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

    PAGE = 4096_u64

    # Bitmap of dirty pages for mprotect barrier (LibC-backed, not GC heap).
    @@mp_base : UInt64 = 0
    @@mp_bits : UInt64* = Pointer(UInt64).null
    @@mp_nwords : Int32 = 0
    @@mp_pages : Int32 = 0
    @@mp_installed = false
    @@mp_enabled = false
    @@mp_old_sa = uninitialized LibC::Sigaction
    @@mp_hits : UInt64 = 0

    def self.mprotect_barrier_enabled? : Bool
      @@mp_enabled
    end

    def self.mprotect_hits : UInt64
      @@mp_hits
    end

    # Install SEGV handler that re-enables write + marks page dirty.
    # Faults outside the registered heap range are forwarded to the previous handler.
    def self.install_mprotect_barrier : Bool
      {% unless flag?(:linux) %}
        return false
      {% end %}
      return true if @@mp_installed

      action = LibC::Sigaction.new
      action.sa_flags = LibC::SA_SIGINFO
      action.sa_sigaction = LibC::SigactionHandlerT.new do |_sig, info, uctx|
        addr = info.value.si_addr.address
        unless Platform.mprotect_fault(addr)
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
    def self.mprotect_set_heap_range(low : UInt64, high : UInt64) : Nil
      clear_mprotect_cards
      return if high <= low
      page_lo = low & ~(PAGE - 1)
      page_hi = (high + PAGE - 1) & ~(PAGE - 1)
      pages = ((page_hi - page_lo) // PAGE).to_i32
      return if pages <= 0 || pages > 16_777_216 # sanity

      nwords = (pages + 63) // 64
      bytes = (nwords * 8).to_u64
      ptr = LibC.malloc(LibC::SizeT.new(bytes)).as(UInt64*)
      return if ptr.null?
      ptr.as(UInt8*).clear(bytes)

      @@mp_base = page_lo
      @@mp_bits = ptr
      @@mp_nwords = nwords
      @@mp_pages = pages
    end

    def self.clear_mprotect_cards : Nil
      unless @@mp_bits.null?
        LibC.free(@@mp_bits.as(Void*))
        @@mp_bits = Pointer(UInt64).null
      end
      @@mp_base = 0
      @@mp_nwords = 0
      @@mp_pages = 0
    end

    # Protect old (non-nursery) size-class / large chunk pages as read-only.
    def self.mprotect_protect_range(low : UInt64, high : UInt64) : Nil
      return unless @@mp_enabled
      return if high <= low
      page_lo = (low + PAGE - 1) & ~(PAGE - 1)
      page_hi = high & ~(PAGE - 1)
      return if page_hi <= page_lo
      LibC.mprotect(Pointer(Void).new(page_lo), LibC::SizeT.new(page_hi - page_lo), LibC::PROT_READ)
    end

    def self.mprotect_unprotect_range(low : UInt64, high : UInt64) : Nil
      return if high <= low
      page_lo = low & ~(PAGE - 1)
      page_hi = (high + PAGE - 1) & ~(PAGE - 1)
      return if page_hi <= page_lo
      LibC.mprotect(Pointer(Void).new(page_lo), LibC::SizeT.new(page_hi - page_lo),
        LibC::PROT_READ | LibC::PROT_WRITE)
    end

    # Called from SEGV handler. Returns true if this was a managed RO page.
    def self.mprotect_fault(addr : UInt64) : Bool
      return false if @@mp_bits.null? || @@mp_pages == 0
      return false if addr < @@mp_base

      idx = ((addr - @@mp_base) // PAGE).to_i32
      return false if idx < 0 || idx >= @@mp_pages

      word = idx >> 6
      bit = idx & 63
      (@@mp_bits + word).value |= 1_u64 << bit
      @@mp_hits &+= 1

      page = @@mp_base + idx.to_u64 * PAGE
      LibC.mprotect(Pointer(Void).new(page), LibC::SizeT.new(PAGE),
        LibC::PROT_READ | LibC::PROT_WRITE)
      true
    end

    def self.each_mprotect_dirty_page(& : UInt64 ->) : Nil
      return if @@mp_bits.null?
      i = 0
      while i < @@mp_pages
        word = i >> 6
        bit = i & 63
        if ((@@mp_bits + word).value & (1_u64 << bit)) != 0
          yield @@mp_base + i.to_u64 * PAGE
        end
        i += 1
      end
    end

    def self.clear_mprotect_dirty_bits : Nil
      return if @@mp_bits.null?
      i = 0
      while i < @@mp_nwords
        (@@mp_bits + i).value = 0_u64
        i += 1
      end
    end

    def self.count_mprotect_dirty_pages : {UInt64, UInt64}
      dirty = 0_u64
      return {0_u64, 0_u64} if @@mp_bits.null?
      i = 0
      while i < @@mp_pages
        word = i >> 6
        bit = i & 63
        dirty += 1 if ((@@mp_bits + word).value & (1_u64 << bit)) != 0
        i += 1
      end
      {dirty, @@mp_pages.to_u64}
    end
  end
end
