# SuspendThread is asynchronous; GetThreadContext completes the suspension
# and captures all integer roots. Never collect after a failed capture.
require "./windows_os"

module Gcry::Platform
  MAX_STW_SP_SLOTS    = 64
  GREG_WORDS          = 80
  GREG_CAPACITY       = MAX_STW_SP_SLOTS * GREG_WORDS
  UCONTEXT_SP_OFFSET  = 152
  UCONTEXT_RSP_OFFSET = UCONTEXT_SP_OFFSET
  @@stw_ids = uninitialized StaticArray(LibC::HANDLE, MAX_STW_SP_SLOTS)
  @@stw_sps = uninitialized StaticArray(UInt64, MAX_STW_SP_SLOTS)
  @@stw_gregs = uninitialized StaticArray(UInt64, GREG_CAPACITY)
  @@stw_greg_ok = uninitialized StaticArray(Bool, MAX_STW_SP_SLOTS)
  @@stw_claimed = uninitialized Atomic(UInt64)
  @@stw_booted = false
  @@stw_enabled = true
  @@stw_installed = false
  @@stw_handles = uninitialized StaticArray(LibC::HANDLE, MAX_STW_SP_SLOTS)
  @@stw_handle_count = 0

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
    @@stw_handle_count = 0
    @@stw_booted = true
  end

  private def self.slot_for(id : LibC::HANDLE) : Int32
    ensure_stw_table
    claimed = @@stw_claimed.get(:acquire)
    i = 0
    while i < MAX_STW_SP_SLOTS
      if (claimed & (1_u64 << i)) != 0 && @@stw_ids[i] == id
        return i
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
            @@stw_sps[i] = 0_u64
            @@stw_greg_ok[i] = false
            return i
          end
          break
        end
        i += 1
      end
      return -1 if i >= MAX_STW_SP_SLOTS
    end
  end

  def self.record_thread_sp(id : LibC::HANDLE, sp : UInt64, uctx : Void* = Pointer(Void).null) : Nil
    i = slot_for(id)
    return if i < 0
    @@stw_sps[i] = sp
  end

  private def self.record_thread_gregs(id : LibC::HANDLE, state : UInt32*) : Nil
    i = slot_for(id)
    return if i < 0
    src = state.as(UInt64*)
    base = i * GREG_WORDS
    j = 0
    while j < 16
      @@stw_gregs[base + j] = src[j]
      j += 1
    end
    @@stw_greg_ok[i] = true
  end

  def self.thread_sp(id : LibC::HANDLE) : Void*?
    return nil unless @@stw_enabled && @@stw_booted
    claimed = @@stw_claimed.get(:acquire)
    i = 0
    while i < MAX_STW_SP_SLOTS
      if (claimed & (1_u64 << i)) != 0 && @@stw_ids[i] == id
        sp = @@stw_sps[i]
        return nil if sp == 0
        return Pointer(Void).new(sp)
      end
      i += 1
    end
    nil
  end

  def self.each_thread_greg(id : LibC::HANDLE, & : Void* ->) : Nil
    return unless @@stw_booted
    claimed = @@stw_claimed.get(:acquire)
    i = 0
    while i < MAX_STW_SP_SLOTS
      if (claimed & (1_u64 << i)) != 0 && @@stw_ids[i] == id
        return unless @@stw_greg_ok[i]
        base = i * GREG_WORDS
        j = 0
        while j < GREG_WORDS
          word = @@stw_gregs[base + j]
          yield Pointer(Void).new(word) unless word == 0
          j += 1
        end
        return
      end
      i += 1
    end
  end

  def self.clear_thread_sps : Nil
    return unless @@stw_booted
    @@stw_claimed.set(0_u64, :release)
    # The register table itself is in a writable PE section. Clear its words
    # so captures from exited threads cannot become permanent static roots.
    @@stw_gregs.to_unsafe.clear(GREG_CAPACITY)
    i = 0
    while i < MAX_STW_SP_SLOTS
      @@stw_sps[i] = 0
      @@stw_greg_ok[i] = false
      i += 1
    end
  end

  def self.reset_stw_after_fork : Nil
    @@stw_installed = false
    ensure_stw_table
    @@stw_claimed.set(0_u64, :release)
    @@stw_handle_count = 0
    i = 0
    while i < MAX_STW_SP_SLOTS
      @@stw_sps[i] = 0
      @@stw_handles[i] = Pointer(Void).null
      i += 1
    end
  end

  def self.sp_from_ucontext(uctx : Void*) : UInt64
    0_u64
  end

  def self.rsp_from_ucontext(uctx : Void*) : UInt64
    0_u64
  end

  def self.install_stw_sp_capture : Nil
    {% unless flag?(:x86_64) || flag?(:aarch64) %}
      return
    {% end %}
    return if @@stw_installed
    ensure_stw_table
    @@stw_installed = true
  end

  def self.stop_world_threads(current : Thread) : Nil
    ensure_stw_table
    Thread.lock
    clear_thread_sps
    @@stw_handle_count = 0
    error = false
    Thread.unsafe_each do |thread|
      next if thread == current
      if @@stw_handle_count == MAX_STW_SP_SLOTS
        error = true
        break
      end
      handle = thread.to_unsafe
      if LibC.SuspendThread(handle) == UInt32::MAX
        error = true
        break
      end
      @@stw_handles[@@stw_handle_count] = handle
      @@stw_handle_count += 1
      buffer = uninitialized UInt8[1248]
      context = buffer.to_unsafe.align_up(16).as(LibC::CONTEXT*)
      context.clear
      context.value.contextFlags = LibC::CONTEXT_FULL
      if LibC.GetThreadContext(handle, context) == 0
        error = true
        break
      end
      record_thread_sp(handle, context.value.rsp)
      record_thread_gregs(handle, (context.as(UInt8*) + offsetof(LibC::CONTEXT, @rax)).as(UInt32*))
      # Windows has nonvolatile XMM registers; a reference need not be in a GP
      # register or stack slot. Scan the saved FP/XMM area as words as well.
      slot = slot_for(handle)
      fp = (context.as(UInt8*) + offsetof(LibC::CONTEXT, @fltSave)).as(UInt64*)
      64.times { |i| @@stw_gregs[slot * GREG_WORDS + 16 + i] = fp[i] }
    end
    if error
      resume_suspended_threads
      Thread.unlock
      clear_thread_sps
      raise "gcry: Windows thread suspension/context capture failed or exceeded 64 threads"
    end
  end

  private def self.resume_suspended_threads : Nil
    while @@stw_handle_count > 0
      @@stw_handle_count -= 1
      handle = @@stw_handles[@@stw_handle_count]
      # A failed resume must not leave the application running with a frozen
      # mutator. This path cannot allocate an exception safely.
      LibC.abort if LibC.ResumeThread(handle) == UInt32::MAX
    end
  end

  def self.start_world_threads(current : Thread) : Nil
    resume_suspended_threads
    Thread.unlock
  end
end
