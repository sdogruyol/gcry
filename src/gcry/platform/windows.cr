require "./windows_os"
require "./windows_stack"
require "./windows_roots"
require "./windows_stw"

module Gcry::Platform
  enum BarrierBackend
    None
    SoftDirty
    Mprotect
  end

  PAGE_SIZE = 4096_u64

  def self.windows_process_gc_supported? : Bool
    true
  end

  def self.clear_soft_dirty : Bool
    false
  end

  def self.each_dirty_page(low : UInt64, high : UInt64, & : UInt64 ->) : Bool
    false
  end

  def self.count_soft_dirty_pages(low : UInt64, high : UInt64) : {UInt64, UInt64}?
    nil
  end

  def self.soft_dirty_supported? : Bool
    false
  end

  def self.install_mprotect_barrier : Bool
    false
  end

  def self.disable_mprotect_barrier : Nil
  end

  def self.mprotect_barrier_enabled? : Bool
    false
  end

  def self.mprotect_hits : UInt64
    0_u64
  end

  def self.mprotect_set_heap_range(low : UInt64, high : UInt64) : Nil
  end

  def self.clear_mprotect_cards : Nil
  end

  def self.mprotect_protect_range(low : UInt64, high : UInt64) : Nil
  end

  def self.mprotect_unprotect_range(low : UInt64, high : UInt64) : Nil
  end

  def self.mprotect_fault(addr : UInt64) : Bool
    false
  end

  def self.each_mprotect_dirty_page(& : UInt64 ->) : Nil
  end

  def self.clear_mprotect_dirty_bits : Nil
  end

  def self.count_mprotect_dirty_pages : {UInt64, UInt64}
    {0_u64, 0_u64}
  end

  def self.host_page_size : UInt64
    OS.sysconf(OS::SC_PAGESIZE).to_u64
  end

  # Decommit/recommit keeps the reservation and guarantees zero-filled pages.
  # MEM_RESET does not guarantee zeroing, which dormant freelist revival needs.
  def self.release_physical_pages(addr : UInt64, len : UInt64) : Bool
    return false if len == 0 || (addr | len) & (host_page_size - 1) != 0
    pointer = Pointer(Void).new(addr)
    return false if LibC.VirtualFree(pointer, len, LibC::MEM_DECOMMIT) == 0
    # The caller will read the range again even when release reports false;
    # inability to recommit must therefore stop the process, not leave a hole.
    LibC.abort if LibC.VirtualAlloc(pointer, len, LibC::MEM_COMMIT, LibC::PAGE_READWRITE).null?
    true
  end

  def self.page_readable?(addr : UInt64) : Bool
    return false if LibC.VirtualQuery(Pointer(Void).new(addr), out info, sizeof(LibC::MEMORY_BASIC_INFORMATION)) == 0
    memory_readable?(info)
  end

  private def self.memory_readable?(info : LibC::MEMORY_BASIC_INFORMATION) : Bool
    info.state == LibC::MEM_COMMIT && (info.protect & (LibC::PAGE_GUARD | 1)) == 0 &&
      (info.protect & 0xEE) != 0
  end

  # VirtualQuery describes a whole run with identical state/protection.
  # Walk every run (including interior guards), without a syscall per page.
  def self.each_readable_region(low : UInt64, high : UInt64, & : UInt64, UInt64 ->) : Nil
    cursor = low
    while cursor < high
      return if LibC.VirtualQuery(Pointer(Void).new(cursor), out info, sizeof(LibC::MEMORY_BASIC_INFORMATION)) == 0
      finish = info.baseAddress.address &+ info.regionSize
      return if finish <= cursor
      finish = high if finish > high
      yield cursor, finish if memory_readable?(info)
      cursor = finish
    end
  end

  def self.os_thread_count : Int32?
    nil
  end

  def self.each_map_region(& : UInt64, UInt64, UInt8*, UInt8*, Int32 ->) : Bool
    false
  end

  def self.atfork_installed? : Bool
    false
  end

  def self.set_atfork_handlers(prepare : -> Nil, parent : -> Nil, child : -> Nil) : Nil
  end

  def self.install_atfork : Nil
  end
end
