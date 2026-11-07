# For the regressions that check that one automatic collection ran: one
# allocation at `gc_threshold = 1` (79, 86), or `GC_collect_a_little` on a
# due debt (27). Before such a window, wait until no thread the process
# started on its own is still being born. A birth allocates, and inside the
# window that allocation collects on the newborn thread. The window's own
# collection then finds that one running (`@collecting`, or the collection
# section taken, which automatic collections skip rather than wait for) and
# returns without one; and when it does not, the collection the post-stop
# hook measured may be the newborn's, from another stack.
#
# - The idle collector (`Gcry::IdleRelease`) is born at the end of the
#   process's first collection and allocates on its own thread (its main
#   `Fiber`) until it exempts itself from stops. So the first collection runs
#   here and the wait lasts until it is exempt: from then on it allocates
#   nothing until it collects at idle, minutes away. It puts itself on
#   Crystal's thread list from its own `Thread#start`, so it may not be
#   listed yet when the collection returns. Regression 86's third arm on
#   windows-latest: 5 of 200 (`bench/log/windows/2026-11-03-reg86-idle-birth/`).
# - On Windows, the IOCP forwarder that `kernel.cr` starts before `main`
#   (`Crystal::EventLoop::IOCP.start_forwarder_thread`). Once its main fiber
#   is current, `Thread#start` copies its name to UTF-16 for
#   `SetThreadDescription` (`System.to_wstr`), an allocation that may collect;
#   after that it blocks in `GetQueuedCompletionStatusEx` and allocates
#   nothing. Regression 79 on windows-11-arm, default and headers: 25 of 800
#   (`bench/log/windows/2026-11-07-reg79-iocp-birth/`). A named thread's birth
#   has done that allocation, and any collection it ran, once Windows holds
#   the thread's description, so the wait covers every named thread.
{% if flag?(:win32) %}
  lib LibC
    fun GetThreadDescription(hThread : HANDLE, ppszThreadDescription : LPWSTR*) : LONG
  end
{% end %}

private def settle_thread_described?(thread : Thread) : Bool
  {% if flag?(:win32) %}
    desc = Pointer(LibC::WCHAR).null
    return false if LibC.GetThreadDescription(thread.@system_handle, pointerof(desc)) < 0
    set = !desc.null? && desc.value != 0
    LibC.LocalFree(desc.as(Void*)) unless desc.null?
    set
  {% else %}
    true
  {% end %}
end

def settle_runtime_threads : Nil
  GC.collect if Gcry::IdleRelease.armed?
  deadline = Time.instant + 10.seconds
  loop do
    idle = !Gcry::IdleRelease.armed?
    # Where `kernel.cr` starts the IOCP forwarder (before `main`), it must
    # be listed.
    iocp = {{ !(flag?(:win32) && (!flag?(:without_mt) && !flag?(:preview_mt) || flag?(:execution_context))) }}
    described = true
    current = Thread.current
    Thread.each do |thread|
      next if thread.same?(current)
      idle = true if Gcry::IdleRelease.signal_exempt?(thread)
      iocp = true if thread.name == "IOCP"
      described = false if thread.name && !settle_thread_described?(thread)
    end
    break if idle && iocp && described
    fail "runtime threads still being born 10 s on (idle exempt #{idle}, IOCP listed #{iocp}, named threads described #{described})" if Time.instant > deadline
    sleep 1.millisecond
  end
end

# Right before a `gc_threshold = 1` window, and before anything the window
# measures is written to the stack: make the debt the allocation's slow
# path checks at least 1. `maybe_collect` reads the credited debt
# (`@bytes_since_gc`), and the slow path credits its own cursor set only
# after it (`bitmap_alloc_locked`), so an allocation whose hit path missed
# for want of a block, right after a collection that nothing has been
# credited since, sees 0 and does not collect. `settle_runtime_threads`'s
# collection left exactly that when nothing else ran first (79 after 27 in
# one process: `Expected 10 to be > 10`). `Heap#bytes_since_gc` credits
# every set.
def credit_window_debt : Nil
  heap = Gcry.default_heap
  return if heap.bytes_since_gc > 0
  block = GC.malloc_atomic(LibC::SizeT.new(64))
  asm("" :: "r"(block) : "memory" : "volatile")
  fail "no debt credited after an allocation" unless heap.bytes_since_gc > 0
end
