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
    # `pthread_getattr_np` is not callable with the world stopped. It takes the
    # *target* thread's descriptor lock, and for the main thread glibc has no
    # recorded stackblock so it parses `/proc/self/maps` through stdio — which
    # mallocs. Either lock can be held by a thread STW has already frozen, and
    # then the collector waits for it forever. That was a real hang, not a
    # theoretical one: `bench/stw_startup_hang.cr` reproduced it on 18 of 150
    # starts, wedged inside this call on the third thread of the scan.
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

    # Drop the previous collection's entries. A pthread_t can be reused by a new
    # thread after the old one exits, so entries are never carried across a
    # collection — a stale one would hand the scan another thread's address
    # range.
    def self.begin_stack_bounds_snapshot : Nil
      @@sb_count = 0
    end

    # Record *thread*'s bounds. Must be called with no thread suspended.
    def self.snapshot_pthread_stack_bounds(thread : LibC::PthreadT) : Nil
      {% if flag?(:linux) %}
        i = @@sb_count
        return if i >= MAX_STACK_BOUNDS_SLOTS
        return unless bounds = pthread_stack_bounds(thread)
        @@sb_ids[i] = thread
        @@sb_low[i] = bounds[0].address
        @@sb_high[i] = bounds[1].address
        @@sb_count = i + 1
      {% end %}
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
