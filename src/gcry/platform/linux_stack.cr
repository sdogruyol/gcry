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
    # The table **grows**, and the reason is that the alternative was a silent
    # coverage cliff: it was a fixed 64 entries, and a process whose thread list
    # is longer than that recorded bounds for the first 64 in list order and
    # nothing for the rest, every collection, for the life of the process.
    # Measured before the change, with threads parked and one collection: 82
    # threads on Crystal's list gave `visited=64 read=64` — full coverage, said
    # the pair whose whole job is to report a gap — and 18 lookups that fell
    # through to `nil`. At 122 threads, 58. A thread with no entry loses the
    # pthread-mapping half of its root coverage: `scan_pthread_stack` returns
    # without scanning, which is where a Parallel worker's scheduler frames live
    # while its SP is on a pool fiber.
    #
    # Growth is safe here without any synchronisation, and that is a property of
    # the caller rather than of this code: the table is written only by the
    # thread stopping the world, between `Thread.lock` and the first suspend
    # signal, and read only by that same thread while the world is stopped. No
    # thread is frozen when `realloc` runs, so it cannot be holding libc's
    # allocator lock against us — the same argument that lets
    # `pthread_getattr_np`, which parses `/proc` for the main thread, be called
    # from here at all.
    STACK_BOUNDS_INITIAL_SLOTS = 64

    @@sb_ids = Pointer(LibC::PthreadT).null
    @@sb_low = Pointer(UInt64).null
    @@sb_high = Pointer(UInt64).null
    @@sb_cap = 0
    @@sb_capacity_misses = 0_u64
    @@sb_nogrow = false
    @@sb_count = 0
    @@sb_misses = 0_u64
    @@sb_visited = 0_u64
    @@sb_read = 0_u64
    # Ids the snapshot has ever read bounds for, so a fault can say whether the
    # thread it died on had worked before. That one bit separates the two
    # readings left after Crystal's own ordering rules the cheap ones out
    # (bench/log/linux/2026-08-16-scheduler-roots-aarch64-segv/FINDINGS.md):
    # a **repeat** means the thread stopped being queryable between two
    # snapshots, a **first-timer** means it never was. Bounded and never
    # cleared; a process with more distinct threads than this simply stops
    # recording, which `sb_seen_full` says out loud rather than silently.
    SEEN_IDS = 64
    @@sb_seen = uninitialized StaticArray(UInt64, SEEN_IDS)
    @@sb_seen_count = 0
    @@sb_seen_full = false
    # Held as a plain word: `LibC::PthreadT` is `ULong` on glibc and a pointer
    # on musl, so neither `.new` nor `.address` is portable. It is an opaque id
    # for a diagnostic line, and 8 bytes either way.
    @@sb_in_flight = 0_u64

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
        # Counted before the capacity check, not after. The old order returned
        # first, so a thread the table had no room for was never recorded as
        # visited either — and `visited == read`, the pair that exists to say
        # "the platform answered nothing for a thread we asked about", read
        # clean while the coverage was gone. A visit is a visit whether or not
        # there is somewhere to put the answer.
        @@sb_visited += 1
        if i >= @@sb_cap && !grow_stack_bounds_table
          @@sb_capacity_misses += 1
          return
        end
        @@sb_in_flight = thread.unsafe_as(UInt64)
        bounds = pthread_stack_bounds(thread)
        @@sb_in_flight = 0_u64
        return unless bounds
        @@sb_read += 1
        note_seen_id(thread.unsafe_as(UInt64))
        @@sb_ids[i] = thread
        @@sb_low[i] = bounds[0].address
        @@sb_high[i] = bounds[1].address
        @@sb_count = i + 1
      {% end %}
    end

    # Doubling, from `STACK_BOUNDS_INITIAL_SLOTS`. Returns false only when the
    # allocator refuses, in which case the caller counts a capacity miss and the
    # visit shows up as `visited` without a matching `read`.
    private def self.grow_stack_bounds_table : Bool
      return false if @@sb_nogrow && @@sb_cap > 0
      want = @@sb_cap == 0 ? STACK_BOUNDS_INITIAL_SLOTS : @@sb_cap * 2
      ids = LibC.realloc(@@sb_ids.as(Void*), LibC::SizeT.new(want * sizeof(LibC::PthreadT)))
      return false if ids.null?
      @@sb_ids = ids.as(LibC::PthreadT*)
      low = LibC.realloc(@@sb_low.as(Void*), LibC::SizeT.new(want * sizeof(UInt64)))
      return false if low.null?
      @@sb_low = low.as(UInt64*)
      high = LibC.realloc(@@sb_high.as(Void*), LibC::SizeT.new(want * sizeof(UInt64)))
      return false if high.null?
      @@sb_high = high.as(UInt64*)
      @@sb_cap = want
      true
    end

    # Research only: refuse to grow past the initial capacity, so the gate can
    # show what the fixed table used to do.
    def self.stack_bounds_nogrow=(value : Bool) : Bool
      @@sb_nogrow = value
    end

    # Threads the snapshot visited and had nowhere to record. Zero is the only
    # acceptable value on a healthy process; a non-zero one means some thread's
    # OS stack is not being scanned.
    def self.stack_bounds_capacity_misses : UInt64
      @@sb_capacity_misses
    end

    private def self.note_seen_id(id : UInt64) : Nil
      i = 0
      while i < @@sb_seen_count
        return if @@sb_seen[i] == id
        i += 1
      end
      if @@sb_seen_count >= SEEN_IDS
        @@sb_seen_full = true
        return
      end
      @@sb_seen[@@sb_seen_count] = id
      @@sb_seen_count += 1
    end

    # Has the snapshot ever read bounds for this thread? Signal-safe: an array
    # scan and nothing else.
    def self.stack_bounds_seen_before?(id : UInt64) : Bool
      i = 0
      while i < @@sb_seen_count
        return true if @@sb_seen[i] == id
        i += 1
      end
      false
    end

    # True once the table stopped recording, so "first time" cannot be read as
    # fact when it might be "we stopped looking".
    def self.stack_bounds_seen_full? : Bool
      @@sb_seen_full
    end

    # Non-zero only while `pthread_getattr_np` is running for that thread, so a
    # crash handler reading it is reading the thread the fault is about.
    def self.stack_bounds_in_flight : UInt64
      @@sb_in_flight
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
