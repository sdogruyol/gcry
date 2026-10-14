require "../../src/gcry"
require "spec"
{% if flag?(:win32) && !flag?(:gnu) %}
  require "c/dbghelp"
{% end %}

# A fatal exception has to end the process. On Windows, two ways of taking one
# hung it instead (`src/gcry/crash_guard.cr`, found on CI on 2026-10-08 and
# captured with `cdb` on 2026-10-14):
#
#   - A thread that faults inside gcry's allocator holds that size class's
#     lock. Crystal's handler allocates to print the backtrace, and its
#     allocation of the same class spun on that lock forever, on the thread
#     that holds it. Here the fault is in a `GC_set_on_heap_resize` callback,
#     which runs during the refill with the class lock held. The allocation
#     that maps the chunk is the size of the `SYMBOL_INFOW` buffer the
#     handler allocates for every frame, so the handler's first frame needs
#     that lock.
#   - A second thread that faults while the first one's report is loading
#     DbgHelp waits on Crystal's `once` for `load_debug_info`. On a thread with
#     no execution context that wait raises, and the raise waits again, until
#     the stack overflows inside whatever lock it was taking. That is the MSVC
#     handler only: the GNU one (aarch64) prints through `dladdr` and is done
#     before the second thread faults.
#
# Each runs in a child of its own. On windows-latest x86_64 against
# origin/master's src (run 38567822241): the first child hung 10 times in 10;
# the second hung 1 time in 20, and the other 19 ended with status 0xC0000005,
# not the 1 Crystal's handler exits with. With the guard: 10 of 10 and 20 of
# 20 exited 1. On Linux both already exited, because Crystal's SIGSEGV
# handler does not allocate.

# A passing child takes about a second, most of it loading DbgHelp's symbols.
# This only bounds a hang.
private CRASH_EXIT_TIMEOUT = 60.seconds

private def crash_child(example : String, env_key : String) : {Process::Status, String}
  output = IO::Memory.new
  child = Process.new(Process.executable_path.not_nil!, ["-e", example],
    env: {env_key => "1"}, output: output, error: output)
  deadline = Time.instant + CRASH_EXIT_TIMEOUT
  until child.terminated?
    if Time.instant > deadline
      child.terminate(graceful: false)
      child.wait
      fail "the child was still running #{CRASH_EXIT_TIMEOUT} after it faulted:\n#{output}"
    end
    sleep 10.milliseconds
  end
  {child.wait, output.to_s}
end

# The size Crystal's Windows handler allocates for each frame it prints
# (`Exception::CallStack.sym_from_addr`, `Pointer(UInt8).malloc`, so atomic).
# Anywhere else any small class will do: nothing there allocates in the report.
private def crash_report_frame_bytes : Int32
  {% if flag?(:win32) && !flag?(:gnu) %}
    sizeof(LibC::SYMBOL_INFOW) + (LibC::MAX_SYM_NAME - 1) * sizeof(LibC::WCHAR)
  {% else %}
    4096
  {% end %}
end

private module CrashInAllocator
  # A literal, read by the callback: the spec runner maps chunks of its own
  # before the example starts.
  class_property? armed = false
end

describe "Regression: a fatal exception ends the process" do
  it "when it lands inside the allocator with a size-class lock held" do
    status, output = crash_child("crash-in-allocator child", "GCRY_CRASH_IN_ALLOCATOR_CHILD")
    fail "the child exited cleanly:\n#{output}" if status.success?
    output.should contain("Invalid memory access")
    {% if flag?(:win32) %}
      # Crystal's handler finished its report and exited.
      status.exit_code?.should eq(1)
    {% end %}
  end

  it "when a second thread faults while the first one's report is running" do
    status, output = crash_child("crash-pair child", "GCRY_CRASH_PAIR_CHILD")
    fail "the child exited cleanly:\n#{output}" if status.success?
    output.should contain("Invalid memory access")
    {% if flag?(:win32) %}
      # The first thread's report ended the process, rather than the second
      # thread's fault inside it.
      status.exit_code?.should eq(1)
    {% end %}
  end

  # The runs, by the examples above in fresh processes; no-ops anywhere else.
  it "crash-in-allocator child" do
    next unless ENV["GCRY_CRASH_IN_ALLOCATOR_CHILD"]? == "1"
    bytes = LibC::SizeT.new(crash_report_frame_bytes)
    # Sized up front, so the loop's only allocations are the ones it makes.
    held = Array(Void*).new(200_000)
    LibGC.set_on_heap_resize(->(size : LibGC::Word) {
      Pointer(Int32).new(0x10_u64).value = 1 if CrashInAllocator.armed?
    })
    CrashInAllocator.armed = true
    200_000.times { held << GC.malloc_atomic(bytes) }
    fail "no chunk was mapped in #{held.size} allocations of #{bytes} bytes"
  end

  it "crash-pair child" do
    next unless ENV["GCRY_CRASH_PAIR_CHILD"]? == "1"
    go = Atomic(Int32).new(0)
    # A bare thread: no execution context, as SYSMON has none.
    Thread.new do
      while go.get == 0
      end
      # Late enough that the main thread's report is the one running.
      Thread.sleep(2.milliseconds)
      Pointer(Int32).new(0x20_u64).value = 1
    end
    go.set(1)
    Pointer(Int32).new(0x10_u64).value = 1
  end
end
