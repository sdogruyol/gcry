require "../../src/gcry"
require "spec"

# `GC_remove_roots` from a thread gcry does not stop (PR #46 review). Boehm's
# takes the allocation lock, so it cannot return while a collection is
# marking, and the caller may free the memory as soon as it does. Until
# 2026-10-09 gcry's stored the range's end down to its start and returned:
# a collection whose hook had already read the range went on scanning it,
# and a C thread that then unmapped it crashed the collector — an
# unregistered thread looping map, `GC_add_roots`, sleep, `GC_remove_roots`,
# unmap next to `GC.collect` took a Windows run down on its first try, in
# `push_root_range` under the roots hook. Registered, the same thread is
# stopped first and never raced.
#
# The thread is a pthread on POSIX and a CRT `_beginthreadex` thread on
# Windows, started straight from the OS so gcry is told nothing about it;
# the file names no `LibC.pthread_*` on Windows (29's header).

# Long enough that a collection scanning it outlasts the thread's sleep.
private REMOVE_SCAN_BYTES       = 64_i64 * 1024 * 1024
private REMOVE_SCAN_COLLECTIONS = 60

# The shared words, in libc memory: the thread has no `Thread`, and nothing
# that would make one may run on it (29's header).
private enum RemoveScanSlot
  Bytes
  Stop
  Cycles
  MapFailed
  Done
  Count
end

private def remove_scan_load(shared : Int64*, slot : RemoveScanSlot) : Int64
  Atomic::Ops.load(shared + slot.value, :sequentially_consistent, true)
end

private def remove_scan_store(shared : Int64*, slot : RemoveScanSlot, value : Int64) : Nil
  Atomic::Ops.store(shared + slot.value, value, :sequentially_consistent, true)
end

# One millisecond, straight from the OS.
private def remove_scan_nap : Nil
  {% if flag?(:win32) %}
    LibC.Sleep(1)
  {% else %}
    ts = LibC::Timespec.new(tv_sec: 0, tv_nsec: 1_000_000)
    LibC.nanosleep(pointerof(ts), nil)
  {% end %}
end

private def remove_scan_map(bytes : UInt64) : Void*
  {% if flag?(:win32) %}
    LibC.VirtualAlloc(nil, LibC::SizeT.new(bytes), LibC::MEM_RESERVE | LibC::MEM_COMMIT, LibC::PAGE_READWRITE)
  {% else %}
    p = LibC.mmap(nil, LibC::SizeT.new(bytes), LibC::PROT_READ | LibC::PROT_WRITE, LibC::MAP_PRIVATE | LibC::MAP_ANON, -1, 0)
    # `MAP_FAILED` is a constant with an initialiser: not on this thread.
    p.address == UInt64::MAX ? Pointer(Void).null : p
  {% end %}
end

private def remove_scan_unmap(p : Void*, bytes : UInt64) : Nil
  {% if flag?(:win32) %}
    LibC.VirtualFree(p, 0, LibC::MEM_RELEASE)
  {% else %}
    LibC.munmap(p, LibC::SizeT.new(bytes))
  {% end %}
end

# The thread's body: a fresh mapping registered, held a moment, taken back
# and unmapped at once, until told to stop.
private def remove_scan_body(shared : Int64*) : Nil
  bytes = remove_scan_load(shared, RemoveScanSlot::Bytes).to_u64
  until remove_scan_load(shared, RemoveScanSlot::Stop) != 0
    p = remove_scan_map(bytes)
    if p.null?
      remove_scan_store(shared, RemoveScanSlot::MapFailed, 1)
      break
    end
    high = (p.as(UInt8*) + bytes).as(Void*)
    LibGC.add_roots(p, high)
    remove_scan_nap
    LibGC.remove_roots(p, high)
    remove_scan_unmap(p, bytes)
    remove_scan_store(shared, RemoveScanSlot::Cycles, remove_scan_load(shared, RemoveScanSlot::Cycles) &+ 1)
  end
  remove_scan_store(shared, RemoveScanSlot::Done, 1)
end

describe "Regression: GC_remove_roots waits for a scan of the range" do
  # In a process of its own: before the fix the collector crashed on the
  # unmapped range, which would take the whole suite down.
  it "does not return while a collection still reads the range it takes back" do
    captured = IO::Memory.new
    status = Process.run(Process.executable_path.not_nil!, ["-e", "remove-roots-scan child"],
      env: {"GCRY_REMOVE_ROOTS_SCAN_CHILD" => "1"}, output: captured, error: captured)
    fail captured.to_s unless status.success?
    captured.to_s.should contain("1 examples, 0 failures")
  end

  # The run, by the example above in a fresh process; a no-op anywhere else.
  it "remove-roots-scan child" do
    next unless ENV["GCRY_REMOVE_ROOTS_SCAN_CHILD"]? == "1"
    shared = LibC.malloc(RemoveScanSlot::Count.value * sizeof(Int64)).as(Int64*)
    shared.clear(RemoveScanSlot::Count.value)
    remove_scan_store(shared, RemoveScanSlot::Bytes, REMOVE_SCAN_BYTES)
    {% if flag?(:win32) %}
      handle = LibC._beginthreadex(nil, 0, ->(arg : Void*) { remove_scan_body(arg.as(Int64*)); 0_u32 }, shared.as(Void*), 0, nil)
      handle.null?.should be_false
    {% else %}
      LibC.pthread_create(out tid, nil, ->(arg : Void*) { remove_scan_body(arg.as(Int64*)); Pointer(Void).null }, shared.as(Void*)).should eq(0)
    {% end %}
    deadline = Time.instant + 30.seconds
    until remove_scan_load(shared, RemoveScanSlot::Cycles) > 0 || remove_scan_load(shared, RemoveScanSlot::Done) != 0
      fail "the thread never finished a cycle" if Time.instant > deadline
      Thread.yield
    end
    REMOVE_SCAN_COLLECTIONS.times { GC.collect }
    remove_scan_store(shared, RemoveScanSlot::Stop, 1)
    {% if flag?(:win32) %}
      LibC.WaitForSingleObject(handle, LibC::INFINITE).should eq(LibC::WAIT_OBJECT_0)
      LibC.CloseHandle(handle)
    {% else %}
      LibC.pthread_join(tid, nil).should eq(0)
    {% end %}
    remove_scan_load(shared, RemoveScanSlot::MapFailed).should eq(0)
    remove_scan_load(shared, RemoveScanSlot::Cycles).should be > 1
    LibC.free(shared.as(Void*))
  end
end
