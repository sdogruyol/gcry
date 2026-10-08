require "../../src/gcry"
require "spec"

# Boehm's registration of a thread C created (PR #44 review): a thread that
# did not come from `GC_pthread_create`/`GC_beginthreadex` or Crystal's
# `Thread.new` calls `GC_register_my_thread`, allocates, and must then be
# stopped and have its stack scanned like any other; `GC_unregister_my_thread`
# takes it back off before it exits. Until 2026-10-06 gcry defined none of
# these, so this file did not link, and until 2026-10-08 Windows answered
# `GC_UNIMPLEMENTED`. Called through gcry's `LibGC`, which declares them ahead
# of their definitions (src/gcry/c_abi.cr).
#
# The thread is a pthread on POSIX and a CRT `_beginthreadex` thread on
# Windows; this file must not name `LibC.pthread_*` there (CI, windows
# x86_64/arm64, 2026-10-06).

{% if flag?(:win32) %}
  lib LibC
    fun GetThreadId(thread : HANDLE) : DWORD
  end
{% end %}

private BLOCKS        =       8
private BLOCK_BYTES   =    4096
private BLOCK_PATTERN = 0xA7_u8

# What the thread does with the registration.
private MODE_NONE        = 0_i64 # never registers
private MODE_REGISTER    = 1_i64 # registers, unregisters before it exits
private MODE_EXIT_LISTED = 2_i64 # registers and exits still registered

# The shared words, in libc memory: the foreign thread has no `Thread`, and
# anything that would make one — a lazily initialised class variable, a
# constant with an initialiser — must not run on it.
private enum Slot
  Phase
  Mode
  RegisteredBefore
  StackBaseResult
  StackBase
  Register
  RegisterAgain
  RegisteredAfter
  Intact
  Unregister
  RegisteredAtEnd
  ThreadId
  ListedWhileHeld
  ListedAfterExit
  Count
end

private def slot_ptr(shared : Int64*, slot : Slot) : Int64*
  shared + slot.value
end

private def load(shared : Int64*, slot : Slot) : Int64
  Atomic::Ops.load(slot_ptr(shared, slot), :sequentially_consistent, true)
end

private def store(shared : Int64*, slot : Slot, value : Int64) : Nil
  Atomic::Ops.store(slot_ptr(shared, slot), value, :sequentially_consistent, true)
end

# One millisecond, straight from the OS: safe on a thread with no `Thread`.
private def nap : Nil
  {% if flag?(:win32) %}
    LibC.Sleep(1)
  {% else %}
    ts = LibC::Timespec.new(tv_sec: 0, tv_nsec: 1_000_000)
    LibC.nanosleep(pointerof(ts), nil)
  {% end %}
end

# The calling thread's OS id, as `listed_id` reads it off a `Thread`.
private def os_thread_id : Int64
  {% if flag?(:win32) %}
    LibC.GetCurrentThreadId.to_i64
  {% else %}
    LibC.pthread_self.unsafe_as(Int64)
  {% end %}
end

private def listed_id(thread : Thread) : Int64
  {% if flag?(:win32) %}
    # A `Thread`'s handle is its own duplicate, never the creator's handle.
    LibC.GetThreadId(thread.to_unsafe).to_i64
  {% else %}
    thread.to_unsafe.unsafe_as(Int64)
  {% end %}
end

private def wait_phase(shared : Int64*, phase : Int64) : Bool
  deadline = Time.instant + 30.seconds
  until load(shared, Slot::Phase) >= phase
    return false if Time.instant > deadline
    nap
  end
  true
end

# The thread's body. Its blocks are held only in `blocks`, on its own stack:
# the collector keeps them only if it scans that stack.
private def foreign_body(shared : Int64*) : Nil
  mode = load(shared, Slot::Mode)
  sb = LibGC::StackBase.new
  store(shared, Slot::ThreadId, os_thread_id)
  store(shared, Slot::RegisteredBefore, LibGC.thread_is_registered.to_i64)
  store(shared, Slot::StackBaseResult, LibGC.get_stack_base(pointerof(sb)).to_i64)
  store(shared, Slot::StackBase, sb.mem_base.address.to_i64!)
  if mode != MODE_NONE
    store(shared, Slot::Register, LibGC.register_my_thread(pointerof(sb)).to_i64)
    store(shared, Slot::RegisterAgain, LibGC.register_my_thread(pointerof(sb)).to_i64)
  end
  store(shared, Slot::RegisteredAfter, LibGC.thread_is_registered.to_i64)
  blocks = uninitialized StaticArray(Void*, 8)
  BLOCKS.times do |i|
    p = LibGC.malloc_atomic(BLOCK_BYTES)
    p.as(UInt8*).fill(BLOCK_BYTES) { BLOCK_PATTERN }
    blocks[i] = p
  end
  store(shared, Slot::Phase, 1)
  until Atomic::Ops.load(slot_ptr(shared, Slot::Phase), :sequentially_consistent, true) >= 2
    nap
  end
  intact = 0
  BLOCKS.times do |i|
    p = blocks[i]
    next unless LibGC.base(p) == p
    ok = true
    BLOCK_BYTES.times { |j| ok = false unless p.as(UInt8*)[j] == BLOCK_PATTERN }
    intact += 1 if ok
  end
  asm("" :: "r"(blocks.to_unsafe) : "memory")
  store(shared, Slot::Intact, intact.to_i64)
  if mode == MODE_REGISTER
    store(shared, Slot::Unregister, LibGC.unregister_my_thread.to_i64)
  end
  store(shared, Slot::RegisteredAtEnd, LibGC.thread_is_registered.to_i64)
  store(shared, Slot::Phase, 3)
end

# Is the thread with this OS id on Crystal's thread list — the set gcry stops
# and scans?
private def listed?(id : Int64) : Bool
  found = false
  Thread.unsafe_each { |t| found = true if listed_id(t) == id }
  found
end

# Runs one foreign thread, collecting from this one while it holds its blocks.
private def run_foreign(mode : Int64) : Int64*
  shared = LibC.malloc(Slot::Count.value * sizeof(Int64)).as(Int64*)
  shared.clear(Slot::Count.value)
  store(shared, Slot::Mode, mode)
  store(shared, Slot::Register, -1)
  store(shared, Slot::Unregister, -1)
  # Straight from the OS, not through `GC`: a thread gcry is told nothing
  # about, as one a C library starts.
  {% if flag?(:win32) %}
    handle = LibC._beginthreadex(nil, 0, ->(arg : Void*) { foreign_body(arg.as(Int64*)); 0_u32 }, shared.as(Void*), 0, nil)
    handle.null?.should be_false
  {% else %}
    LibC.pthread_create(out tid, nil, ->(arg : Void*) { foreign_body(arg.as(Int64*)); Pointer(Void).null }, shared.as(Void*)).should eq(0)
  {% end %}
  wait_phase(shared, 1).should be_true
  store(shared, Slot::ListedWhileHeld, listed?(load(shared, Slot::ThreadId)) ? 1_i64 : 0_i64)
  5.times do
    LibGC.collect
    # Churn over whatever the collection freed, so a reclaimed block reads
    # zeros rather than the thread's pattern.
    2_000.times { LibGC.malloc_atomic(BLOCK_BYTES).as(UInt8*).clear(BLOCK_BYTES) }
  end
  store(shared, Slot::Phase, 2)
  wait_phase(shared, 3).should be_true
  {% if flag?(:win32) %}
    LibC.WaitForSingleObject(handle, LibC::INFINITE).should eq(LibC::WAIT_OBJECT_0)
    LibC.CloseHandle(handle)
  {% else %}
    LibC.pthread_join(tid, nil).should eq(0)
  {% end %}
  store(shared, Slot::ListedAfterExit, listed?(load(shared, Slot::ThreadId)) ? 1_i64 : 0_i64)
  shared
end

# The registration half both registering examples share.
private def check_registered(shared : Int64*) : Nil
  load(shared, Slot::RegisteredBefore).should eq(0)
  load(shared, Slot::StackBaseResult).should eq(0) # GC_SUCCESS
  load(shared, Slot::StackBase).should_not eq(0)
  load(shared, Slot::Register).should eq(0)      # GC_SUCCESS
  load(shared, Slot::RegisterAgain).should eq(1) # GC_DUPLICATE
  load(shared, Slot::RegisteredAfter).should eq(1)
  load(shared, Slot::ListedWhileHeld).should eq(1)
  load(shared, Slot::Intact).should eq(BLOCKS)
end

# Off Crystal's thread list again, and the exited thread costs the next stops
# nothing.
private def check_gone(shared : Int64*) : Nil
  load(shared, Slot::ListedAfterExit).should eq(0)
  before = Gcry.default_heap.collections
  3.times { LibGC.collect }
  Gcry.default_heap.collections.should be >= before + 3
end

describe "Boehm's foreign-thread registration in a gcry program" do
  it "registers a C thread, stops and scans it, and takes it back off" do
    LibGC.allow_register_threads
    LibGC.thread_is_registered.should eq(1)

    shared = run_foreign(MODE_REGISTER)
    check_registered(shared)
    load(shared, Slot::Unregister).should eq(0)
    load(shared, Slot::RegisteredAtEnd).should eq(0)
    check_gone(shared)
    LibC.free(shared.as(Void*))
  end

  # Boehm requires the unregister, and C code forgets it. A thread left on the
  # list once it is gone is one every later stop must suspend: the exit key
  # (an FLS slot on Windows) takes it off as it ends.
  it "takes a C thread that exits still registered off the list" do
    shared = run_foreign(MODE_EXIT_LISTED)
    check_registered(shared)
    load(shared, Slot::Unregister).should eq(-1)
    load(shared, Slot::RegisteredAtEnd).should eq(1)
    check_gone(shared)
    LibC.free(shared.as(Void*))
  end

  # The control: the same thread unregistered is invisible to the collector,
  # so its blocks are collected under it. Without this the examples above
  # could pass on a collector that never freed anything.
  it "does not keep an unregistered C thread's blocks" do
    shared = run_foreign(MODE_NONE)
    load(shared, Slot::RegisteredBefore).should eq(0)
    load(shared, Slot::RegisteredAfter).should eq(0)
    load(shared, Slot::ListedWhileHeld).should eq(0)
    # 0 of 8 in 8 of 8 runs (2026-10-06); the last block of the thread's
    # cursor may be held as in flight.
    load(shared, Slot::Intact).should be <= 1
    LibC.free(shared.as(Void*))
  end
end
