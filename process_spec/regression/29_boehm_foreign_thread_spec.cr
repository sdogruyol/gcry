require "../../src/gcry"
require "spec"

# Boehm's registration of a thread C created (PR #44 review): a pthread that
# did not come from `GC_pthread_create` or Crystal's `Thread.new` calls
# `GC_register_my_thread`, allocates, and must then be stopped and have its
# stack scanned like any other; `GC_unregister_my_thread` takes it back off
# before it exits. Until 2026-10-06 gcry defined none of these, so this file
# did not link. Called through gcry's `LibGC`, which declares them ahead of
# their definitions (src/gcry/c_abi.cr).

private BLOCKS        =       8
private BLOCK_BYTES   =    4096
private BLOCK_PATTERN = 0xA7_u8

# The shared words, in libc memory: the foreign thread has no `Thread`, and
# anything that would make one — a lazily initialised class variable, a
# constant with an initialiser — must not run on it.
private enum Slot
  Phase
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

# One millisecond, through libc: safe on a thread with no `Thread`.
private def nap : Nil
  ts = LibC::Timespec.new(tv_sec: 0, tv_nsec: 1_000_000)
  LibC.nanosleep(pointerof(ts), nil)
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
private def foreign_body(shared : Int64*, register : Bool) : Nil
  sb = LibGC::StackBase.new
  store(shared, Slot::ThreadId, LibC.pthread_self.unsafe_as(Int64))
  store(shared, Slot::RegisteredBefore, LibGC.thread_is_registered.to_i64)
  store(shared, Slot::StackBaseResult, LibGC.get_stack_base(pointerof(sb)).to_i64)
  store(shared, Slot::StackBase, sb.mem_base.address.to_i64!)
  if register
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
  if register
    store(shared, Slot::Unregister, LibGC.unregister_my_thread.to_i64)
  end
  store(shared, Slot::RegisteredAtEnd, LibGC.thread_is_registered.to_i64)
  store(shared, Slot::Phase, 3)
end

# Is the thread with this pthread id on Crystal's thread list — the set gcry
# stops and scans?
private def listed?(id : Int64) : Bool
  found = false
  Thread.unsafe_each { |t| found = true if t.to_unsafe.unsafe_as(Int64) == id }
  found
end

# Runs one foreign thread, collecting from this one while it holds its blocks.
private def run_foreign(register : Bool) : Int64*
  shared = LibC.malloc(Slot::Count.value * sizeof(Int64)).as(Int64*)
  shared.clear(Slot::Count.value)
  store(shared, Slot::Register, -1)
  store(shared, Slot::Unregister, -1)
  body = register ? ->(arg : Void*) { foreign_body(arg.as(Int64*), true); Pointer(Void).null } : ->(arg : Void*) { foreign_body(arg.as(Int64*), false); Pointer(Void).null }
  # `LibC.pthread_create`, not `GC.pthread_create`: a thread gcry is told
  # nothing about, as one a C library starts.
  LibC.pthread_create(out tid, nil, body, shared.as(Void*)).should eq(0)
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
  LibC.pthread_join(tid, nil).should eq(0)
  store(shared, Slot::ListedAfterExit, listed?(load(shared, Slot::ThreadId)) ? 1_i64 : 0_i64)
  shared
end

describe "Boehm's foreign-thread registration in a gcry program" do
  it "registers a C thread, stops and scans it, and takes it back off" do
    LibGC.allow_register_threads
    LibGC.thread_is_registered.should eq(1)

    shared = run_foreign(register: true)
    load(shared, Slot::RegisteredBefore).should eq(0)
    load(shared, Slot::StackBaseResult).should eq(0) # GC_SUCCESS
    load(shared, Slot::StackBase).should_not eq(0)
    load(shared, Slot::Register).should eq(0)      # GC_SUCCESS
    load(shared, Slot::RegisterAgain).should eq(1) # GC_DUPLICATE
    load(shared, Slot::RegisteredAfter).should eq(1)
    load(shared, Slot::ListedWhileHeld).should eq(1)
    load(shared, Slot::Intact).should eq(BLOCKS)
    load(shared, Slot::Unregister).should eq(0)
    load(shared, Slot::RegisteredAtEnd).should eq(0)

    # Off Crystal's thread list again, and the exited thread costs the next
    # stops nothing.
    load(shared, Slot::ListedAfterExit).should eq(0)
    LibC.free(shared.as(Void*))
    before = Gcry.default_heap.collections
    3.times { LibGC.collect }
    Gcry.default_heap.collections.should be >= before + 3
  end

  # The control: the same thread unregistered is invisible to the collector,
  # so its blocks are collected under it. Without this the example above could
  # pass on a collector that never freed anything.
  it "does not keep an unregistered C thread's blocks" do
    shared = run_foreign(register: false)
    load(shared, Slot::RegisteredBefore).should eq(0)
    load(shared, Slot::RegisteredAfter).should eq(0)
    load(shared, Slot::ListedWhileHeld).should eq(0)
    # 0 of 8 in 8 of 8 runs (2026-10-06); the last block of the thread's
    # cursor may be held as in flight.
    load(shared, Slot::Intact).should be <= 1
    LibC.free(shared.as(Void*))
  end
end
