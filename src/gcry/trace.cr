# GC event trace — NDJSON lines for debugging (Phase 7.1).
#
# Enable: `GCRY_TRACE=1`
# Optional: `GCRY_TRACE_FILE=/tmp/gcry.ndjson` (default: stderr fd 2)
# Alloc sampling: `GCRY_TRACE_ALLOC_SAMPLE=N` (default 1000 = 1/1000; 0 disables alloc lines)
#
# Under `-Dgc_none` we must avoid:
#   - `require "json"` (JSON::Builder ↔ GC.malloc cycle)
#   - writing through abstract `IO` (pulls OpenSSL::SSL::Socket into codegen)
# Emit with `RawOut` into a stack buffer + reentrancy guard.

require "./platform/os"
require "./raw_out"

module Gcry
  module Trace
    @@enabled = false
    @@emitting = false
    @@fd = 2
    @@owned_fd = false
    @@alloc_sample = 1000_u64
    @@alloc_tick = Atomic(UInt64).new(0)

    def self.enabled? : Bool
      @@enabled
    end

    # *fd* is a raw OS file descriptor (default stderr). Tests may pass a pipe/file fd.
    def self.enable(fd : Int32 = 2, alloc_sample : UInt64 = 1000_u64, owned : Bool = false) : Nil
      close_owned
      @@fd = fd
      @@owned_fd = owned
      @@alloc_sample = alloc_sample
      @@enabled = true
    end

    def self.disable : Nil
      @@enabled = false
      close_owned
      @@fd = 2
    end

    def self.init_from_env : Nil
      return unless ENV["GCRY_TRACE"]? == "1"

      sample = 1000_u64
      if s = ENV["GCRY_TRACE_ALLOC_SAMPLE"]?
        sample = s.to_u64? || 1000_u64
      end

      if path = ENV["GCRY_TRACE_FILE"]?
        fd = Gcry::OS.open(path, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_TRUNC, 0o644)
        if fd >= 0
          enable(fd, alloc_sample: sample, owned: true)
          return
        end
      end
      enable(2, alloc_sample: sample, owned: false)
    end

    # Inlined shells, so the allocation hit path pays one flag test rather
    # than a call: `Heap#malloc` was calling this out of line on every hit,
    # visible as a `call Trace::after_malloc` in the release disassembly.
    @[AlwaysInline]
    def self.after_malloc(ptr : Void*, size : UInt64, atomic : Bool) : Nil
      return unless @@enabled
      after_malloc_enabled(ptr, size, atomic)
    end

    @[AlwaysInline]
    def self.after_free(ptr : Void*) : Nil
      return unless @@enabled
      after_free_enabled(ptr)
    end

    private def self.after_malloc_enabled(ptr : Void*, size : UInt64, atomic : Bool) : Nil
      return if ptr.null?
      return if @@alloc_sample == 0
      n = @@alloc_tick.add(1)
      return unless (n % @@alloc_sample) == 0
      with_emit("alloc") do |buf, len|
        len = append_ptr(buf, len, ptr)
        len = append_u64(buf, len, "size", size)
        len = append_bool(buf, len, "atomic", atomic)
        len
      end
    end

    private def self.after_free_enabled(ptr : Void*) : Nil
      return if ptr.null?
      return if @@alloc_sample == 0
      n = @@alloc_tick.add(1)
      return unless (n % @@alloc_sample) == 0
      with_emit("free") do |buf, len|
        append_ptr(buf, len, ptr)
      end
    end

    def self.collect_start(major : Bool) : Nil
      return unless @@enabled
      with_emit("collect_start") do |buf, len|
        append_bool(buf, len, "major", major)
      end
    end

    def self.collect_end(heap : Heap, major : Bool) : Nil
      return unless @@enabled
      with_emit("collect_end") do |buf, len|
        len = append_bool(buf, len, "major", major)
        len = append_u64(buf, len, "collections", heap.collections)
        len = append_u64(buf, len, "live_objects", heap.live_objects)
        len = append_u64(buf, len, "heap_size", heap.heap_size)
        len = append_u64(buf, len, "pause_ns", heap.last_pause_ns)
        len = append_u64(buf, len, "clear_ns", heap.last_phase_clear_ns)
        len = append_u64(buf, len, "scrub_ns", heap.last_phase_scrub_ns)
        len = append_u64(buf, len, "roots_ns", heap.last_phase_roots_ns)
        len = append_u64(buf, len, "static_ns", heap.last_phase_static_ns)
        len = append_u64(buf, len, "stacks_ns", heap.last_phase_stacks_ns)
        len = append_u64(buf, len, "mark_ns", heap.last_phase_mark_ns)
        len = append_u64(buf, len, "sweep_ns", heap.last_phase_sweep_ns)
        len = append_u64(buf, len, "stw_stop_ns", heap.last_phase_stw_stop_ns)
        len = append_u64(buf, len, "stw_start_ns", heap.last_phase_stw_start_ns)
        # The schedule the sweep just set, and what sized it: the next major's
        # threshold, the live bytes it was derived from, the bytes the mark
        # read and the pace (`Heap#threshold_pace_pct`). Without them a
        # collection count cannot be told apart from a threshold change when
        # a trigger policy is being cut.
        len = append_u64(buf, len, "threshold", heap.gc_threshold)
        len = append_u64(buf, len, "size_class_live_bytes", heap.size_class_live_bytes)
        len = append_u64(buf, len, "scanned_bytes", heap.mark_scanned_bytes)
        len = append_u64(buf, len, "threshold_pace_pct", heap.threshold_pace_pct)
        # Post-STW reclaim (munmap / dormant / page release / large trim).
        append_u64(buf, len, "flush_ns", heap.last_phase_flush_ns)
      end
    end

    def self.barrier_arm(backend : String) : Nil
      return unless @@enabled
      with_emit("barrier_arm") do |buf, len|
        append_str(buf, len, "backend", backend)
      end
    end

    def self.finalizer(kind : String, object : Void*) : Nil
      return unless @@enabled
      with_emit("finalizer") do |buf, len|
        len = append_str(buf, len, "kind", kind)
        append_ptr(buf, len, object)
      end
    end

    private def self.close_owned : Nil
      if @@owned_fd && @@fd >= 0 && @@fd != 2
        Gcry::OS.close(@@fd)
      end
      @@owned_fd = false
    end

    private def self.with_emit(event : String, & : UInt8*, Int32 -> Int32) : Nil
      return if @@emitting
      @@emitting = true
      begin
        # A `collect_end` line is 337 bytes with every number zero, 481 with
        # nine-digit values and 680 at full width, so it does not fit
        # `RawOut::LIMIT`. Each field first calls `room`, which writes out the
        # line so far when the field might not fit: a long line leaves in
        # several `write`s with the same bytes, and `@@emitting` stays set
        # across them so no other event lands in between.
        buf = uninitialized UInt8[RawOut::LIMIT]
        len = RawOut.append(buf.to_unsafe, 0, "{\"event\":\"")
        len = RawOut.append(buf.to_unsafe, len, event)
        len = RawOut.append(buf.to_unsafe, len, "\",\"ts_ns\":")
        ts = Clock.monotonic_ns.to_i64!
        if ts < 0
          len = RawOut.append(buf.to_unsafe, len, "-")
          len = RawOut.append_u64(buf.to_unsafe, len, (-ts).to_u64)
        else
          len = RawOut.append_u64(buf.to_unsafe, len, ts.to_u64)
        end
        len = yield buf.to_unsafe, len
        len = room(buf.to_unsafe, len, 2)
        len = RawOut.append(buf.to_unsafe, len, "}\n")
        RawOut.flush(buf.to_unsafe, len, @@fd)
      ensure
        @@emitting = false
      end
    end

    # Writes out the line so far if *need* more bytes might not fit.
    private def self.room(buf : UInt8*, len : Int32, need : Int32) : Int32
      return len if len + need <= RawOut::LIMIT
      RawOut.flush(buf, len, @@fd)
      0
    end

    private def self.append_ptr(buf : UInt8*, len : Int32, ptr : Void*) : Int32
      len = room(buf, len, 27)
      len = RawOut.append(buf, len, ",\"ptr\":\"0x")
      len = RawOut.append_hex(buf, len, ptr.address)
      RawOut.append(buf, len, "\"")
    end

    private def self.append_str(buf : UInt8*, len : Int32, key : String, value : String) : Int32
      len = room(buf, len, key.bytesize + value.bytesize + 6)
      len = RawOut.append(buf, len, ",\"")
      len = RawOut.append(buf, len, key)
      len = RawOut.append(buf, len, "\":\"")
      len = RawOut.append(buf, len, value)
      RawOut.append(buf, len, "\"")
    end

    private def self.append_u64(buf : UInt8*, len : Int32, key : String, value : UInt64) : Int32
      len = room(buf, len, key.bytesize + 24)
      len = RawOut.append(buf, len, ",\"")
      len = RawOut.append(buf, len, key)
      len = RawOut.append(buf, len, "\":")
      RawOut.append_u64(buf, len, value)
    end

    private def self.append_bool(buf : UInt8*, len : Int32, key : String, value : Bool) : Int32
      len = room(buf, len, key.bytesize + 9)
      len = RawOut.append(buf, len, ",\"")
      len = RawOut.append(buf, len, key)
      len = RawOut.append(buf, len, "\":")
      RawOut.append(buf, len, value ? "true" : "false")
    end
  end
end

# At require time, not in `GC.init` with the other knobs: enabled there, the
# first traced allocation (`Thread.init`'s) reads `@@alloc_tick` through
# `__crystal_once` before `Crystal::Once.init`, which allocates again and
# deadlocks on its own spin lock (measured 2026-10-12).
Gcry::Trace.init_from_env
