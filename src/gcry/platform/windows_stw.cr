# SuspendThread is asynchronous; GetThreadContext completes the suspension
# and captures all integer roots. Never collect after a failed capture.
require "./windows_os"

module Gcry::Platform
  # Where the capture table starts. It used to be a hard maximum, and this
  # platform's answer to reaching it was to **refuse the stop**:
  # `try_stop_world_threads` checked the count before suspending and
  # `raise_thread_suspension_error` said "or exceeded 64 threads". No missed
  # root and no hang — but a process with 65 threads could not collect at all,
  # which trades a bounded loss for an unbounded heap. The table now grows.
  STW_INITIAL_SLOTS = 64
  {% if flag?(:aarch64) %}
    GREG_WORDS = 96 # X0-X30, SP, and 32 128-bit SIMD registers
  {% else %}
    GREG_WORDS = 80 # RAX-R15 and the 512-byte FP/XMM save area
  {% end %}
  UCONTEXT_SP_OFFSET  = 152
  UCONTEXT_RSP_OFFSET = UCONTEXT_SP_OFFSET
  # `LibC`-allocated and grown before the first `SuspendThread`. Static arrays
  # are what forced the bound: at GREG_WORDS = 80 per slot a table for a
  # thousand threads is most of a megabyte in a writable PE section, and
  # `clear_thread_sps` already has to wipe that section so its words cannot
  # become permanent static roots.
  @@stw_capacity = 0
  @@stw_ids = Pointer(LibC::HANDLE).null
  @@stw_sps = Pointer(UInt64).null
  @@stw_gregs = Pointer(UInt64).null
  @@stw_greg_ok = Pointer(UInt8).null
  # One byte per slot, not a 64-bit mask — the mask could not address a 65th
  # slot. No CAS: `slot_for` runs only on the collector here, from
  # `try_stop_world_threads`, one thread at a time.
  @@stw_claimed = Pointer(UInt8).null
  @@stw_handles = Pointer(LibC::HANDLE).null
  @@stw_handle_count = 0
  # `GCRY_STW_FIXED_SLOTS=1`: never grow, which is the pre-fix bound.
  @@stw_fixed_slots = uninitialized Bool
  @@stw_booted = false
  @@stw_enabled = true
  @@stw_installed = false
  # Slot claims that found the table full. This platform used to refuse the
  # whole stop rather than reach that case, so the counter was a structural
  # zero; now that the table grows it is the instrument the raise used to be,
  # and `make stw-capture-coverage` asserts it stays zero. It moves when the
  # allocator refuses a bigger table or `GCRY_STW_FIXED_SLOTS=1` pins it.
  @@stw_capture_no_slot = uninitialized UInt64

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
    @@stw_handle_count = 0
    @@stw_capture_no_slot = 0_u64
    @@stw_fixed_slots = false
    @@stw_booted = true
    grow_stw_table(STW_INITIAL_SLOTS)
  end

  # Grows the capture and handle tables to at least *want* slots, doubling.
  # False when the allocator refuses, leaving the old tables in place: the stop
  # then covers what fits and `stw_capture_no_slot` counts the rest, which is
  # the trade this platform used to make in the other direction.
  #
  # No copy — every slot is per-STW and callers grow before the first suspend.
  private def self.grow_stw_table(want : Int32) : Bool
    return true if want <= @@stw_capacity
    cap = @@stw_capacity < STW_INITIAL_SLOTS ? STW_INITIAL_SLOTS : @@stw_capacity
    while cap < want
      cap *= 2
    end

    ids = LibC.malloc(LibC::SizeT.new(cap.to_u64 * sizeof(LibC::HANDLE)))
    sps = LibC.malloc(LibC::SizeT.new(cap.to_u64 * sizeof(UInt64)))
    gregs = LibC.malloc(LibC::SizeT.new(cap.to_u64 * GREG_WORDS.to_u64 * sizeof(UInt64)))
    greg_ok = LibC.malloc(LibC::SizeT.new(cap.to_u64))
    claimed = LibC.malloc(LibC::SizeT.new(cap.to_u64))
    handles = LibC.malloc(LibC::SizeT.new(cap.to_u64 * sizeof(LibC::HANDLE)))
    if ids.null? || sps.null? || gregs.null? || greg_ok.null? || claimed.null? || handles.null?
      LibC.free(ids)
      LibC.free(sps)
      LibC.free(gregs)
      LibC.free(greg_ok)
      LibC.free(claimed)
      LibC.free(handles)
      return false
    end

    LibC.free(@@stw_ids.as(Void*))
    LibC.free(@@stw_sps.as(Void*))
    LibC.free(@@stw_gregs.as(Void*))
    LibC.free(@@stw_greg_ok.as(Void*))
    LibC.free(@@stw_claimed.as(Void*))
    LibC.free(@@stw_handles.as(Void*))

    @@stw_ids = ids.as(LibC::HANDLE*)
    @@stw_sps = sps.as(UInt64*)
    @@stw_gregs = gregs.as(UInt64*)
    @@stw_greg_ok = greg_ok.as(UInt8*)
    @@stw_claimed = claimed.as(UInt8*)
    @@stw_handles = handles.as(LibC::HANDLE*)
    @@stw_capacity = cap

    i = 0
    while i < cap
      @@stw_claimed[i] = 0_u8
      @@stw_greg_ok[i] = 0_u8
      i += 1
    end
    # The greg rows are cleared because `clear_thread_sps` keeps them clear:
    # a captured word left behind in a freshly grown table would be scanned.
    @@stw_gregs.clear(cap.to_u64 * GREG_WORDS.to_u64)
    true
  end

  def self.stw_slot_capacity : Int32
    @@stw_capacity
  end

  def self.stw_fixed_slots=(value : Bool) : Bool
    ensure_stw_table
    @@stw_fixed_slots = value
  end

  def self.stw_fixed_slots? : Bool
    @@stw_booted && @@stw_fixed_slots
  end

  def self.stw_capture_no_slot : UInt64
    @@stw_booted ? @@stw_capture_no_slot : 0_u64
  end

  # Plain loads and stores: the collector is the only caller here, from
  # `try_stop_world_threads`, one thread at a time. The CAS this used to do was
  # defensive on this platform and it is why the table was a 64-bit mask.
  private def self.slot_for(id : LibC::HANDLE) : Int32
    ensure_stw_table
    i = 0
    while i < @@stw_capacity
      return i if @@stw_claimed[i] != 0 && @@stw_ids[i] == id
      i += 1
    end
    i = 0
    while i < @@stw_capacity
      if @@stw_claimed[i] == 0
        @@stw_claimed[i] = 1_u8
        @@stw_ids[i] = id
        @@stw_sps[i] = 0_u64
        @@stw_greg_ok[i] = 0_u8
        return i
      end
      i += 1
    end
    @@stw_capture_no_slot &+= 1
    -1
  end

  def self.record_thread_sp(id : LibC::HANDLE, sp : UInt64, uctx : Void* = Pointer(Void).null) : Nil
    i = slot_for(id)
    return if i < 0
    @@stw_sps[i] = sp
  end

  private def self.record_thread_context(id : LibC::HANDLE, context : LibC::CONTEXT*) : Nil
    record_thread_context_at(slot_for(id), context)
  end

  # Same, for a slot the caller already has: `try_stop_world_threads` walks the
  # threads itself, so it hands the index down rather than having the capture
  # re-derive it through a linear scan.
  private def self.record_thread_context_at(i : Int32, context : LibC::CONTEXT*) : Nil
    return if i < 0
    base = i * GREG_WORDS
    {% if flag?(:aarch64) %}
      @@stw_sps[i] = context.value.sp
      31.times { |j| @@stw_gregs[base + j] = context.value.x[j] }
      @@stw_gregs[base + 31] = context.value.sp
      simd = (context.as(UInt8*) + offsetof(LibC::CONTEXT, @v)).as(UInt64*)
      64.times { |j| @@stw_gregs[base + 32 + j] = simd[j] }
    {% else %}
      @@stw_sps[i] = context.value.rsp
      integer = (context.as(UInt8*) + offsetof(LibC::CONTEXT, @rax)).as(UInt64*)
      16.times { |j| @@stw_gregs[base + j] = integer[j] }
      simd = (context.as(UInt8*) + offsetof(LibC::CONTEXT, @fltSave)).as(UInt64*)
      64.times { |j| @@stw_gregs[base + 16 + j] = simd[j] }
    {% end %}
    @@stw_greg_ok[i] = 1_u8
  end

  def self.thread_sp(id : LibC::HANDLE) : Void*?
    return nil unless @@stw_enabled && @@stw_booted
    i = 0
    while i < @@stw_capacity
      if @@stw_claimed[i] != 0 && @@stw_ids[i] == id
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
    i = 0
    while i < @@stw_capacity
      if @@stw_claimed[i] != 0 && @@stw_ids[i] == id
        return if @@stw_greg_ok[i] == 0
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
    # The register words are cleared, not just flagged: a capture left behind
    # by an exited thread would otherwise sit in memory the scan reaches.
    @@stw_gregs.clear(@@stw_capacity.to_u64 * GREG_WORDS.to_u64)
    i = 0
    while i < @@stw_capacity
      @@stw_claimed[i] = 0_u8
      @@stw_sps[i] = 0_u64
      @@stw_greg_ok[i] = 0_u8
      i += 1
    end
  end

  def self.reset_stw_after_fork : Nil
    @@stw_installed = false
    ensure_stw_table
    clear_thread_sps
    @@stw_handle_count = 0
    i = 0
    while i < @@stw_capacity
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
    raise_thread_suspension_error unless try_stop_world_threads(current)
  end

  # Failure is allocation-free so the heap can release its root/finalizer
  # locks before constructing an exception and its allocating backtrace.
  def self.try_stop_world_threads(current : Thread) : Bool
    ensure_stw_table
    Thread.lock
    clear_thread_sps

    # Size the tables **before** the first `SuspendThread`. Nothing is frozen
    # yet, so the allocator's own lock is safe to take; doing this inside the
    # stopped world is the 2026-08-10 hang. The slack covers threads that
    # appear between the count and the loop.
    unless @@stw_fixed_slots
      n = 0
      Thread.unsafe_each { n += 1 }
      grow_stw_table(n + 8)
    end

    @@stw_handle_count = 0
    error = false
    Thread.unsafe_each do |thread|
      next if thread == current
      # No bound check here any more. This platform used to fail the whole stop
      # at the 64th thread — correct, loud, and it meant a process with 65
      # threads could never collect. A thread the table cannot hold is now
      # suspended and scanned without its SP clamp or registers, counted in
      # `stw_capture_no_slot`, which is the same trade Linux makes.
      handle = thread.to_unsafe
      if LibC.SuspendThread(handle) == UInt32::MAX
        error = true
        break
      end
      if @@stw_handle_count < @@stw_capacity
        @@stw_handles[@@stw_handle_count] = handle
        @@stw_handle_count += 1
      end
      buffer = uninitialized UInt8[1248]
      context = buffer.to_unsafe.align_up(16).as(LibC::CONTEXT*)
      context.clear
      context.value.contextFlags = LibC::CONTEXT_FULL
      if LibC.GetThreadContext(handle, context) == 0
        error = true
        break
      end
      record_thread_context_at(slot_for(handle), context)
    end
    if error
      resume_suspended_threads
      Thread.unlock
      clear_thread_sps
      return false
    end
    true
  end

  def self.raise_thread_suspension_error : NoReturn
    {% if flag?(:gc_none) %}
      process_heap = Gcry.default_heap?
      process_heap.try &.suppress_collect_enter
    {% end %}
    begin
      raise "gcry: Windows thread suspension or context capture failed"
    ensure
      {% if flag?(:gc_none) %}
        process_heap.try &.suppress_collect_leave
      {% end %}
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
