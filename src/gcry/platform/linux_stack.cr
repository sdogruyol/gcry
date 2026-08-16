require "c/pthread"

module Gcry
  # Linux pthread stack bounds (for STW root scanning / main-fiber setup).
  module Platform
    # Returns {stack_low, stack_high} for *thread*, or nil on failure.
    # *stack_high* is the exclusive top (stack grows down toward *stack_low*).
    def self.pthread_stack_bounds(thread : LibC::PthreadT) : {Void*, Void*}?
      {% if flag?(:linux) %}
        attr = uninitialized LibC::PthreadAttrT
        return nil unless LibC.pthread_getattr_np(thread, pointerof(attr)) == 0

        begin
          addr = Pointer(Void).null
          size = LibC::SizeT.new(0)
          return nil unless LibC.pthread_attr_getstack(pointerof(attr), pointerof(addr), pointerof(size)) == 0
          return nil if addr.null? || size == 0

          high = Pointer(Void).new(addr.address + size.to_u64)
          {addr, high}
        ensure
          LibC.pthread_attr_destroy(pointerof(attr))
        end
      {% else %}
        nil
      {% end %}
    end

    def self.current_pthread_stack_bounds : {Void*, Void*}?
      {% if flag?(:linux) %}
        pthread_stack_bounds(LibC.pthread_self)
      {% else %}
        nil
      {% end %}
    end

    # ── Stack bounds snapshot: bounds without libc, for use under STW ─────────
    #
    # `pthread_getattr_np` is not callable with the world stopped: it takes the
    # *target* thread's descriptor lock, and a thread STW has frozen can be
    # holding its own. The collector then waits for it forever. That was a real
    # hang, not a theoretical one: `bench/stw_startup_hang.cr` reproduced it on
    # 18 of 150 starts, wedged inside this call.
    #
    # It is specifically about *asking glibc about a suspended thread*, and not
    # about libc under STW in general — which was measured, against a positive
    # control firing at 4–9% in the same binary:
    #
    #   live call for every thread          4 of 100 hang   (control)
    #   live call for non-main threads      9 of 100 hang
    #   live call for the main thread only  0 of 100
    #   LibC.malloc 64 KiB x8 under STW     0 of 100
    #   fopen("/proc/self/maps") under STW  0 of 100
    #
    # So the main thread's `/proc/self/maps` parse is not the trigger, malloc is
    # not the trigger, and the collector's other libc use is not implicated.
    #
    # So the bounds are taken while every thread is still running — from
    # `stop_world`, under `Thread.lock` and before the first suspend signal — and
    # the scan under STW does a table lookup instead. The number of
    # `pthread_getattr_np` calls per collection is unchanged; they just no longer
    # happen inside the suspension window, which also takes the `/proc` parse out
    # of the pause.
    #
    # Ownership: written only by the thread stopping the world, between
    # `Thread.lock` and `Thread.unlock`, and read only by that same thread while
    # the world is stopped. No synchronisation is needed and none is implied.
    MAX_STACK_BOUNDS_SLOTS = 64

    @@sb_ids = uninitialized StaticArray(LibC::PthreadT, MAX_STACK_BOUNDS_SLOTS)
    @@sb_low = uninitialized StaticArray(UInt64, MAX_STACK_BOUNDS_SLOTS)
    @@sb_high = uninitialized StaticArray(UInt64, MAX_STACK_BOUNDS_SLOTS)
    @@sb_count = 0
    @@sb_misses = 0_u64
    @@sb_visited = 0_u64
    @@sb_read = 0_u64
    @@sb_in_flight = LibC::PthreadT.new(0)

    # Drop the previous collection's entries. A pthread_t can be reused by a new
    # thread after the old one exits, so entries are never carried across a
    # collection — a stale one would hand the scan another thread's address
    # range.
    def self.begin_stack_bounds_snapshot : Nil
      @@sb_count = 0
    end

    # Record *thread*'s bounds. Must be called with no thread suspended.
    #
    # The two counters and the in-flight id exist because this call has SEGV'd
    # twice on aarch64 CI — 2026-08-16, in `make scheduler-roots` and then in
    # `make ec-queue-audit` — inside `pthread_getattr_np`, leaving one hex
    # address and a libc frame
    # (`bench/log/linux/2026-08-16-scheduler-roots-aarch64-segv/FINDINGS.md`).
    # A visit that produces no bounds is the same shape as the register gaps
    # v0.19.0 closed: the caller assumes coverage and the platform returns
    # nothing. `visited` against `read` makes that countable instead of silent,
    # and `in_flight` means the next fault names the thread rather than the
    # frame.
    def self.snapshot_pthread_stack_bounds(thread : LibC::PthreadT) : Nil
      {% if flag?(:linux) %}
        i = @@sb_count
        return if i >= MAX_STACK_BOUNDS_SLOTS
        @@sb_visited += 1
        @@sb_in_flight = thread
        bounds = pthread_stack_bounds(thread)
        @@sb_in_flight = LibC::PthreadT.new(0)
        return unless bounds
        @@sb_read += 1
        @@sb_ids[i] = thread
        @@sb_low[i] = bounds[0].address
        @@sb_high[i] = bounds[1].address
        @@sb_count = i + 1
      {% end %}
    end

    # Non-zero only while `pthread_getattr_np` is running for that thread, so a
    # crash handler reading it is reading the thread the fault is about.
    def self.stack_bounds_in_flight : UInt64
      {% if flag?(:linux) %}
        @@sb_in_flight.as(UInt64)
      {% else %}
        0_u64
      {% end %}
    end

    # Threads the snapshot walked, and the subset it got bounds for. Equal
    # counts mean full coverage; a gap is a thread whose pthread mapping the
    # root scan does not have.
    def self.stack_bounds_visited : UInt64
      @@sb_visited
    end

    def self.stack_bounds_read : UInt64
      @@sb_read
    end

    # STW-safe lookup: no libc, no locks, no allocation.
    def self.snapshotted_stack_bounds(thread : LibC::PthreadT) : {Void*, Void*}?
      {% if flag?(:linux) %}
        i = 0
        n = @@sb_count
        while i < n
          if LibC.pthread_equal(@@sb_ids[i], thread) != 0
            return {Pointer(Void).new(@@sb_low[i]), Pointer(Void).new(@@sb_high[i])}
          end
          i += 1
        end
        # Not a silent nil: a miss costs the pthread-mapping half of that
        # thread's root coverage, so it has to be countable. Reachable if the
        # thread list outgrows the table, or if a thread joined it after the
        # snapshot (which `Thread.lock` is held to prevent).
        @@sb_misses += 1
        nil
      {% else %}
        nil
      {% end %}
    end

    def self.stack_bounds_snapshot_misses : UInt64
      @@sb_misses
    end
  end
end
