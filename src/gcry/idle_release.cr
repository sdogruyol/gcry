# Give the warm budget back when the process goes idle. Opt-in:
# `GCRY_IDLE_RELEASE_MS=<ms>`.
#
# The sweep keeps up to one threshold of emptied chunks mapped ("warm") so the
# next cycle refills them without faulting fresh pages in. That is the right
# trade while the process allocates and the wrong one once it stops: nothing in
# gcry runs without an allocation to drive it, so the warm chunks stay resident
# for as long as the process idles. Measured on Kemal `/json`: 19.9 MB idle
# against 13.3 MB after `/gc-collect` and Boehm's 13.4 MB
# (`bench/log/linux/2026-09-23-idle-rss-grace/FINDINGS.md`).
#
# This is the clock. A raw pthread — outside Crystal's list for the same reason
# as the STW watchdog and the mark helpers, and holding no GC object — polls the
# heap's cumulative allocation counter. When it has not moved for the configured
# time, the releaser turns every empty, cursor-free bitmap chunk *dormant* and
# runs the existing dormant flush over it: `MADV_DONTNEED` on the data pages,
# address space kept, and the chunk revived on demand through
# `bitmap_revive_dormant` exactly as if the sweep had made it dormant. Once per
# idle stretch; allocation re-arms it.
#
# Soundness rests on protocols that already exist, not on new ones:
#
#   * No collection runs concurrently: the releaser holds `@post_stw_mutex`,
#     which every cycle holds from before the stop to after its flushes.
#   * No cursor can take a chunk as it turns dormant: the take path checks
#     candidacy and sets CURSOR under the chunk-list lock
#     (`bitmap_take_pool_chunk`), and the transition here re-checks CURSOR,
#     PINNED, DORMANT and `occ` under the same lock. Allocation only ever
#     writes `occ` through a cursor-held chunk, so an empty chunk no cursor
#     holds stays empty until a cursor takes it — which it now cannot.
#   * No revive can land inside the page release: the flush runs inside
#     `during_live_chunk_walk`, and `bitmap_revive_dormant` refuses while that
#     flag is set (and counts it, `dormant_revive_during_flush`).
#
# `make idle-release` holds it: checksummed allocation in bursts separated by
# idle gaps, with `GCRY_IDLE_RELEASE_UNCHECKED=1` — which skips the `occ` test
# and so releases chunks holding live objects — as the arm that must corrupt.

require "./platform/os"
require "./clock"

# C ABI entry: not a Crystal::Thread, so STW never suspends it and it never
# needs the Crystal runtime (no fibers, no allocation).
fun gcry_idle_release_main(arg : Void*) : Void*
  Gcry::IdleRelease.loop_forever
  Pointer(Void).null
end

module Gcry
  module IdleRelease
    @@idle_ns = 0_u64
    @@started = false

    def self.idle_ms=(ms : UInt64) : Nil
      @@idle_ns = ms * 1_000_000_u64
    end

    def self.idle_ms : UInt64
      @@idle_ns // 1_000_000_u64
    end

    def self.armed? : Bool
      @@idle_ns > 0
    end

    # From the first collection, with the world running — `pthread_create`
    # asks libc for a stack, which must not happen with threads frozen.
    def self.ensure_started : Nil
      return unless armed?
      return if @@started
      @@started = true
      tid = uninitialized Gcry::OS::PthreadT
      ret = Gcry::OS.pthread_create(pointerof(tid), Pointer(Gcry::OS::PthreadAttrT).null,
        ->gcry_idle_release_main(Void*), Pointer(Void).null)
      if ret != 0
        @@started = false
        msg = "gcry: GCRY_IDLE_RELEASE_MS could not start its thread (pthread_create failed)\n"
        Gcry::OS.write(2, msg.to_unsafe, LibC::SizeT.new(msg.bytesize))
        return
      end
      # `gcry-` is the prefix the thread census subtracts as gcry's own.
      Gcry::Platform.name_own_thread(tid, "gcry-idle")
      Gcry::OS.pthread_detach(tid)
    end

    def self.loop_forever : Nil
      # Poll at a quarter of the idle time, clamped: responsive enough that the
      # release lands within ~1.25x the configured delay, rare enough that an
      # idle process wakes a few times a second at most.
      poll = @@idle_ns // 4
      poll = 10_000_000_u64 if poll < 10_000_000_u64
      poll = 1_000_000_000_u64 if poll > 1_000_000_000_u64
      req = uninitialized Gcry::OS::Timespec
      req.tv_sec = typeof(req.tv_sec).new(poll // 1_000_000_000_u64)
      req.tv_nsec = typeof(req.tv_nsec).new(poll % 1_000_000_000_u64)
      rem = uninitialized Gcry::OS::Timespec

      heap = Gcry.default_heap
      last_total = heap.total_bytes
      last_change = Clock.monotonic_ns
      released = false
      loop do
        Gcry::OS.nanosleep(pointerof(req), pointerof(rem))
        total = heap.total_bytes
        now = Clock.monotonic_ns
        if total != last_total
          last_total = total
          last_change = now
          released = false
          next
        end
        next if released
        next if now - last_change < @@idle_ns
        heap.idle_release
        released = true
      end
    end
  end
end
