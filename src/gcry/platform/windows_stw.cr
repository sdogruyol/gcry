# SuspendThread is asynchronous; GetThreadContext completes the suspension
# and captures all integer roots. Never collect after a failed capture.
require "./windows_os"

module Gcry::Platform
  # The capture table lives in `Gcry::StwSlots`, shared with Darwin and covered
  # by `spec/stw_slots_spec.cr`. It used to be four static arrays and a 64-bit
  # claim mask here, and this platform's answer to reaching that bound was to
  # **refuse the stop**: `try_stop_world_threads` checked the count before
  # suspending and `raise_thread_suspension_error` said "or exceeded 64
  # threads". No missed root and no hang — but a process with 65 threads could
  # not collect at all, which trades a bounded loss for an unbounded heap.
  {% if flag?(:aarch64) %}
    GREG_WORDS = 96 # X0-X30, SP, and 32 128-bit SIMD registers
  {% else %}
    GREG_WORDS = 80 # RAX-R15 and the 512-byte FP/XMM save area
  {% end %}
  UCONTEXT_SP_OFFSET  = 152
  UCONTEXT_RSP_OFFSET = UCONTEXT_SP_OFFSET
  # Handles suspended in the current STW, for the matched resume. Grown with the
  # capture table so a stop is never bounded by it either.
  STW_INITIAL_HANDLES = 64
  # `uninitialized`, not `Pointer(LibC::HANDLE).null`, and `ci/once-guard.py`
  # enforces that now. A class variable declared with a non-literal initializer
  # is set up lazily behind `Crystal.once`, which takes a process-wide mutex —
  # and the first read of this one is in `resume_suspended_threads`, **inside
  # the stopped world**, where a suspended thread can be holding that mutex and
  # nothing will ever resume it. Written the obvious way it wedged all six
  # Windows jobs for their entire 20-minute budget, three runs in a row, with
  # the spec suite stuck mid-example. The same expression crashed Darwin at
  # startup in `stw_slots.cr` two attempts earlier: there the first read is in
  # `GC.init`, before `Crystal.main` sets the once machinery up.
  @@stw_handles = uninitialized LibC::HANDLE*
  @@stw_handle_capacity = 0
  @@stw_handle_count = 0
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
    # Defaults first, and every `uninitialized` one of them: until this runs
    # they hold whatever was in that memory.
    @@stw_handles = Pointer(LibC::HANDLE).null
    @@stw_handle_capacity = 0
    @@stw_handle_count = 0
    @@stw_booted = true
    StwSlots.configure(GREG_WORDS)
    grow_handles(STW_INITIAL_HANDLES)
  end

  # The resume list, grown the same way and for the same reason as the capture
  # table: never freed, so a stale reader cannot fault, and never grown inside
  # the stopped world.
  private def self.grow_handles(want : Int32) : Bool
    return true if want <= @@stw_handle_capacity
    cap = @@stw_handle_capacity < STW_INITIAL_HANDLES ? STW_INITIAL_HANDLES : @@stw_handle_capacity
    while cap < want
      cap *= 2
    end
    fresh = LibC.malloc(LibC::SizeT.new(cap.to_u64 * sizeof(LibC::HANDLE)))
    return false if fresh.null?
    base = fresh.as(LibC::HANDLE*)
    i = 0
    while i < cap
      base[i] = Pointer(Void).null
      i += 1
    end
    @@stw_handles = base
    @@stw_handle_capacity = cap
    true
  end

  def self.stw_capture_no_slot : UInt64
    StwSlots.no_slot
  end

  def self.stw_slot_capacity : Int32
    StwSlots.capacity
  end

  # `GCRY_STW_FIXED_SLOTS=1`: pin the capture table at the 64 slots that
  # shipped, which is the red arm for `make stw-capture-coverage`.
  def self.stw_fixed_slots=(value : Bool) : Bool
    ensure_stw_table
    StwSlots.pinned = value
  end

  def self.stw_fixed_slots? : Bool
    StwSlots.pinned?
  end

  # `GCRY_STW_TEST_FAIL_SUSPEND=1`: refuse the stop as if `SuspendThread` had
  # failed. The only way left to reach the failure path from a test. Until the
  # capture table grew, 65 threads reached it — this platform answered a full
  # table by refusing the whole collection — and
  # `process_spec/regression/9_windows_suspension_capacity_spec.cr` used that to
  # cover the thing the failure path exists for: allocating the exception and
  # its backtrace **without** recursing into a collection, and restoring
  # `Thread.lock`, the STW ownership and `@suppress_collect` on the way out.
  # That was a real bug. The trigger is a knob now instead of a thread count.
  @@stw_test_fail_suspend = false

  def self.stw_test_fail_suspend=(value : Bool) : Bool
    @@stw_test_fail_suspend = value
  end

  def self.stw_test_fail_suspend? : Bool
    @@stw_test_fail_suspend
  end

  private def self.slot_for(id : LibC::HANDLE) : Int32
    ensure_stw_table
    StwSlots.slot_for(id.address.to_u64)
  end

  def self.record_thread_sp(id : LibC::HANDLE, sp : UInt64, uctx : Void* = Pointer(Void).null) : Nil
    StwSlots.record_sp(slot_for(id), sp)
  end

  private def self.record_thread_context(id : LibC::HANDLE, context : LibC::CONTEXT*) : Nil
    record_thread_context_at(slot_for(id), context)
  end

  # Into a slot the caller already claimed: `try_stop_world_threads` walks the
  # threads itself, so it hands the index down instead of having the capture
  # re-derive it through a linear scan.
  private def self.record_thread_context_at(slot : Int32, context : LibC::CONTEXT*) : Nil
    return if slot < 0
    row = uninitialized UInt64[GREG_WORDS]
    {% if flag?(:aarch64) %}
      31.times { |j| row[j] = context.value.x[j] }
      row[31] = context.value.sp
      simd = (context.as(UInt8*) + offsetof(LibC::CONTEXT, @v)).as(UInt64*)
      64.times { |j| row[32 + j] = simd[j] }
      StwSlots.record_sp(slot, context.value.sp)
    {% else %}
      integer = (context.as(UInt8*) + offsetof(LibC::CONTEXT, @rax)).as(UInt64*)
      16.times { |j| row[j] = integer[j] }
      simd = (context.as(UInt8*) + offsetof(LibC::CONTEXT, @fltSave)).as(UInt64*)
      64.times { |j| row[16 + j] = simd[j] }
      StwSlots.record_sp(slot, context.value.rsp)
    {% end %}
    StwSlots.record_gregs(slot, row.to_unsafe, GREG_WORDS)
  end

  def self.thread_sp(id : LibC::HANDLE) : Void*?
    return nil unless @@stw_enabled && @@stw_booted
    sp = StwSlots.sp(id.address.to_u64)
    return nil if sp == 0
    Pointer(Void).new(sp)
  end

  def self.each_thread_greg(id : LibC::HANDLE, & : Void* ->) : Nil
    return unless @@stw_booted
    StwSlots.each_greg(id.address.to_u64) do |word|
      yield Pointer(Void).new(word)
    end
  end

  def self.clear_thread_sps : Nil
    return unless @@stw_booted
    # The register words are cleared, not just flagged: a capture left behind by
    # an exited thread would otherwise sit in memory the scan reaches.
    StwSlots.clear
  end

  def self.reset_stw_after_fork : Nil
    @@stw_installed = false
    ensure_stw_table
    StwSlots.clear
    @@stw_handle_count = 0
    i = 0
    while i < @@stw_handle_capacity
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

    # Size both tables **before** the first `SuspendThread`: nothing is frozen
    # yet, so the allocator's own lock is safe to take, and taking it inside the
    # stopped world is the 2026-08-10 hang. The slack covers threads that appear
    # between the count and the loop.
    n = 0
    Thread.unsafe_each { n += 1 }
    StwSlots.reserve(n + 8)
    grow_handles(n + 8)

    @@stw_handle_count = 0
    error = @@stw_test_fail_suspend
    Thread.unsafe_each do |thread|
      break if error
      next if thread == current
      # No bound check here any more. This platform used to fail the whole stop
      # at the 64th thread — correct, loud, and it meant a process with 65
      # threads could never collect. A thread the tables cannot hold is now
      # suspended and scanned without its SP clamp or registers, counted in
      # `stw_capture_no_slot`, which is the trade Linux already makes.
      handle = thread.to_unsafe
      if LibC.SuspendThread(handle) == UInt32::MAX
        error = true
        break
      end
      if @@stw_handle_count < @@stw_handle_capacity
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
