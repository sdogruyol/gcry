{% skip_file unless ((flag?(:linux) || flag?(:darwin)) && !flag?(:android)) || flag?(:win32) %}

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
# nowhere else.
#
# Windows has `GC_beginthreadex` in its place (`GC_win32_start_inner`), and
# until 2026-10-08 gcry's aborted. Same examples, plus what only it has: the
# caller's `initflag` and `thrdaddr`, and the routine's exit code as the
# thread's. Called through gcry's `LibGC`, as C code bound to Boehm calls them
# (src/gcry/c_abi.cr); this file must not name `LibC.pthread_*` on Windows.

{% if flag?(:win32) %}
  lib LibC
    fun GetThreadId(thread : HANDLE) : DWORD
    fun GetExitCodeThread(thread : HANDLE, code : DWORD*) : BOOL
    fun _endthreadex(code : UInt) : NoReturn
  end
{% else %}
  lib LibC
    fun pthread_exit(value : Void*) : NoReturn
  end
{% end %}

private BLOCKS        =       8
private BLOCK_BYTES   =    4096
private BLOCK_PATTERN = 0x6B_u8
# The routine's result, which `GC_beginthreadex` makes the thread's exit code.
private EXIT_CODE = 0x5A_u32

# The shared words, in libc memory, as in spec 29.
private enum Slot
  Phase
  RegisteredInside
  ThreadId
  ListedWhileHeld
  Intact
  ListedAfterExit
  ExitCode
  ArgIntact
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

# One millisecond, straight from the OS.
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

# The routine's body. Its blocks are held only in `blocks`, on its own stack:
# the collector keeps them only if it scans that stack.
private def started_body(shared : Int64*) : Nil
  store(shared, Slot::ThreadId, os_thread_id)
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
  Thread.unsafe_each { |t| found = true if listed_id(t) == id }
  found
end

# Collects from this thread while the started one holds its blocks.
private def collect_and_churn : Nil
  5.times do
    LibGC.collect
    # Churn over whatever the collection freed, so a reclaimed block reads
    # zeros rather than the thread's pattern.
    2_000.times { LibGC.malloc_atomic(BLOCK_BYTES).as(UInt8*).clear(BLOCK_BYTES) }
  end
end

private def new_shared : Int64*
  shared = LibC.malloc(Slot::Count.value * sizeof(Int64)).as(Int64*)
  shared.clear(Slot::Count.value)
  store(shared, Slot::RegisteredInside, -1)
  store(shared, Slot::ExitCode, -1)
  store(shared, Slot::ArgIntact, -1)
  shared
end

# Starts one thread through `GC_pthread_create` / `GC_beginthreadex`. *leave*
# ends the routine with `pthread_exit` / `_endthreadex` rather than a return,
# which passes over the trampoline's own unregister.
private def run_started(leave : Bool) : Int64*
  shared = new_shared
  {% if flag?(:win32) %}
    body = if leave
             ->(arg : Void*) : UInt32 { started_body(arg.as(Int64*)); LibC._endthreadex(EXIT_CODE) }
           else
             ->(arg : Void*) : UInt32 { started_body(arg.as(Int64*)); EXIT_CODE }
           end
    thrdaddr = 0_u32
    handle = LibGC.beginthreadex(nil, 0, body, shared.as(Void*), 0, pointerof(thrdaddr))
    handle.null?.should be_false
  {% else %}
    body = if leave
             ->(arg : Void*) : Void* { started_body(arg.as(Int64*)); LibC.pthread_exit(Pointer(Void).null) }
           else
             ->(arg : Void*) : Void* { started_body(arg.as(Int64*)); Pointer(Void).null }
           end
    LibGC.pthread_create(out tid, nil, body, shared.as(Void*)).should eq(0)
  {% end %}
  wait_phase(shared, 1).should be_true
  store(shared, Slot::ListedWhileHeld, listed?(load(shared, Slot::ThreadId)) ? 1_i64 : 0_i64)
  collect_and_churn
  store(shared, Slot::Phase, 2)
  wait_phase(shared, 3).should be_true
  {% if flag?(:win32) %}
    LibC.WaitForSingleObject(handle, LibC::INFINITE).should eq(LibC::WAIT_OBJECT_0)
    LibC.GetExitCodeThread(handle, out code).should_not eq(0)
    store(shared, Slot::ExitCode, code.to_i64)
    LibC.CloseHandle(handle)
    # Boehm hands `thrdaddr` to `_beginthreadex` as it came.
    thrdaddr.to_i64.should eq(load(shared, Slot::ThreadId))
  {% else %}
    LibGC.pthread_join(tid, nil).should eq(0)
  {% end %}
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
  {% if flag?(:win32) %}
    load(shared, Slot::ExitCode).should eq(EXIT_CODE)
  {% end %}
  LibC.free(shared.as(Void*))
  before = Gcry.default_heap.collections
  3.times { LibGC.collect }
  Gcry.default_heap.collections.should be >= before + 3
end

{% if flag?(:win32) %}
  # The argument, a collected block: word 0 the shared words, then the pattern.
  private ARG_WORDS = 64

  private def arg_body(token : Int64*) : UInt32
    shared = Pointer(Int64).new(token[0].to_u64!)
    ok = LibGC.base(token.as(Void*)) == token.as(Void*)
    (1...ARG_WORDS).each { |i| ok = false unless token[i] == 0x6B6B_6B6B_6B6B_6B6B_i64 &+ i }
    store(shared, Slot::ArgIntact, ok ? 1_i64 : 0_i64)
    store(shared, Slot::RegisteredInside, LibGC.thread_is_registered.to_i64)
    EXIT_CODE
  end

  # Makes the argument and the suspended thread in a frame of its own, so what
  # is left of it on this thread's stack is overwritten by the collections.
  @[NoInline]
  private def start_suspended(shared : Int64*) : Void*
    token = LibGC.malloc_atomic(ARG_WORDS * sizeof(Int64)).as(Int64*)
    token[0] = shared.address.to_i64!
    (1...ARG_WORDS).each { |i| token[i] = 0x6B6B_6B6B_6B6B_6B6B_i64 &+ i }
    LibGC.beginthreadex(nil, 0, ->(arg : Void*) { arg_body(arg.as(Int64*)) }, token.as(Void*),
      LibC::CREATE_SUSPENDED.to_u32, nil)
  end
{% end %}

describe "GC_pthread_create / GC_beginthreadex in a gcry program" do
  it "runs the routine registered, stops and scans its thread, and takes it back off" do
    check_started(run_started(leave: false))
  end

  it "takes a thread that leaves by pthread_exit / _endthreadex back off the list" do
    check_started(run_started(leave: true))
  end

  {% if flag?(:win32) %}
    # Boehm keeps the argument in uncollectable memory until the thread has
    # registered; gcry roots it for the thread's life. Started suspended, as
    # the caller asked, the thread holds nothing while this one collects: the
    # argument is reachable only through that root.
    it "keeps the argument of a thread started suspended until it runs" do
      shared = new_shared
      handle = start_suspended(shared)
      handle.null?.should be_false
      collect_and_churn
      LibC.ResumeThread(handle).should eq(1)
      LibC.WaitForSingleObject(handle, LibC::INFINITE).should eq(LibC::WAIT_OBJECT_0)
      LibC.GetExitCodeThread(handle, out code).should_not eq(0)
      LibC.CloseHandle(handle)
      code.should eq(EXIT_CODE)
      load(shared, Slot::ArgIntact).should eq(1)
      load(shared, Slot::RegisteredInside).should eq(1)
      LibC.free(shared.as(Void*))
    end
  {% end %}
end
