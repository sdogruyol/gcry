# Darwin soft-dirty / mprotect stubs + capability flag.
# Real stack / roots / STW / atfork live in darwin_{stack,roots,stw}.cr + linux_fork.cr.

require "c/pthread"
require "c/sys/mman"
require "c/unistd"

lib LibMachVM
  alias MachPort = UInt32
  alias KernReturn = Int32
  alias VmAddress = UInt64
  alias VmSize = UInt64
  alias VmProt = Int32

  $mach_task_self_ : MachPort
  fun mach_vm_deallocate(target : MachPort, address : VmAddress, size : VmSize) : KernReturn
  fun mach_vm_allocate(target : MachPort, address : VmAddress*, size : VmSize, flags : Int32) : KernReturn
  fun mach_vm_protect(target : MachPort, address : VmAddress, size : VmSize, set_max : Int32, new_prot : VmProt) : KernReturn
end

module Gcry
  module Platform
    {% if flag?(:darwin) %}
      enum BarrierBackend
        None
        SoftDirty
        Mprotect
      end

      PAGE_SIZE = 4096_u64

      VM_FLAGS_FIXED = 0
      VM_PROT_READ   = 1
      VM_PROT_WRITE  = 2

      def self.darwin_process_gc_supported? : Bool
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

      # Host page size (16 KiB on Apple Silicon, 4 KiB on Intel).
      def self.host_page_size : UInt64
        sz = LibC.sysconf(LibC::SC_PAGESIZE)
        sz > 0 ? sz.to_u64 : 16384_u64
      end

      # Drop physical pages while keeping the VA reserved.
      # Darwin rejects MAP_FIXED over a subrange of an existing mmap; use
      # mach_vm_deallocate + mach_vm_allocate(FIXED) instead (RSS actually falls).
      # Ranges must be host-page aligned (16 KiB on arm64 macOS).
      def self.release_physical_pages(addr : UInt64, len : UInt64) : Bool
        return false if len == 0
        page = host_page_size
        return false if (addr & (page - 1)) != 0
        return false if (len & (page - 1)) != 0

        task = LibMachVM.mach_task_self_
        kr = LibMachVM.mach_vm_deallocate(task, addr, len)
        return false if kr != 0

        slot = addr
        kr = LibMachVM.mach_vm_allocate(task, pointerof(slot), len, VM_FLAGS_FIXED)
        if kr != 0 || slot != addr
          return false
        end

        LibMachVM.mach_vm_protect(task, addr, len, 0, VM_PROT_READ | VM_PROT_WRITE) == 0
      end
    {% end %}
  end
end
