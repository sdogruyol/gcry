{% skip_file unless (flag?(:linux) || flag?(:darwin)) && !flag?(:android) %}

require "../../src/gcry"
require "spec"

# Boehm's `GC_pthread_create` (PR #44 review) registers the thread it starts
# before the routine runs and unregisters it when the routine returns
# (`GC_pthread_start`), so a C thread started through it is stopped and has its
# stack scanned like any other. Until 2026-10-07 gcry's called `pthread_create`
# with the caller's routine as it was: the thread was never on Crystal's thread
# list — the set gcry stops and scans — so what it held only on its stack was
# swept under it, as for the unregistered thread in
# `29_boehm_foreign_thread_spec.cr`. Linux and Darwin: gcry registers C threads
# nowhere else. Called through gcry's `LibGC`, as C code bound to Boehm calls it
# (src/gcry/c_abi.cr).

lib LibC
  fun pthread_exit(value : Void*) : NoReturn
end

private BLOCKS        =       8
private BLOCK_BYTES   =    4096
private BLOCK_PATTERN = 0x6B_u8

# The shared words, in libc memory, as in spec 29.
private enum Slot
  Phase
  RegisteredInside
  ThreadId
  ListedWhileHeld
  Intact
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

# One millisecond, through libc.
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

# The routine's body. Its blocks are held only in `blocks`, on its own stack:
# the collector keeps them only if it scans that stack.
private def started_body(shared : Int64*) : Nil
  store(shared, Slot::ThreadId, LibC.pthread_self.unsafe_as(Int64))
  store(shared, Slot::RegisteredInside, LibGC.thread_is_registered.to_i64)
  blocks = uninitialized StaticArray(Void*, 8)
  BLOCKS.times do |i|
    p = LibGC.malloc_atomic(BLOCK_BYTES)
    p.as(UInt8*).fill(BLOCK_BYTES) { BLOCK_PATTERN }
    blocks[i] = p
  end
  store(shared, Slot::Phase, 1)
  until load(shared, Slot::Phase) >= 2
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
  store(shared, Slot::Phase, 3)
end

private def listed?(id : Int64) : Bool
  found = false
  Thread.unsafe_each { |t| found = true if t.to_unsafe.unsafe_as(Int64) == id }
  found
end

# Starts one thread through `GC_pthread_create`, collecting from this one
# while it holds its blocks. *leave* ends the routine with `pthread_exit`
# rather than a return, which passes over the trampoline's own unregister.
private def run_started(leave : Bool) : Int64*
  shared = LibC.malloc(Slot::Count.value * sizeof(Int64)).as(Int64*)
  shared.clear(Slot::Count.value)
  store(shared, Slot::RegisteredInside, -1)
  body = if leave
           ->(arg : Void*) : Void* { started_body(arg.as(Int64*)); LibC.pthread_exit(Pointer(Void).null) }
         else
           ->(arg : Void*) : Void* { started_body(arg.as(Int64*)); Pointer(Void).null }
         end
  LibGC.pthread_create(out tid, nil, body, shared.as(Void*)).should eq(0)
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
  LibGC.pthread_join(tid, nil).should eq(0)
  store(shared, Slot::ListedAfterExit, listed?(load(shared, Slot::ThreadId)) ? 1_i64 : 0_i64)
  shared
end

private def check_started(shared : Int64*) : Nil
  load(shared, Slot::RegisteredInside).should eq(1)
  load(shared, Slot::ListedWhileHeld).should eq(1)
  load(shared, Slot::Intact).should eq(BLOCKS)
  # Off Crystal's thread list again: a listed thread that is gone is one
  # every later stop signals and waits for.
  load(shared, Slot::ListedAfterExit).should eq(0)
  LibC.free(shared.as(Void*))
  before = Gcry.default_heap.collections
  3.times { LibGC.collect }
  Gcry.default_heap.collections.should be >= before + 3
end

describe "GC_pthread_create in a gcry program" do
  it "runs the routine registered, stops and scans its thread, and takes it back off" do
    check_started(run_started(leave: false))
  end

  it "takes a thread that leaves by pthread_exit back off the list" do
    check_started(run_started(leave: true))
  end
end
