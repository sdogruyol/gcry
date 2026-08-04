# GC event trace — NDJSON lines for debugging (Phase 7.1).
#
# Enable: `GCRY_TRACE=1`
# Optional: `GCRY_TRACE_FILE=/tmp/gcry.ndjson` (default: stderr fd 2)
# Alloc sampling: `GCRY_TRACE_ALLOC_SAMPLE=N` (default 1000 = 1/1000; 0 disables alloc lines)
#
# Under `-Dgc_none` we must avoid:
#   - `require "json"` (JSON::Builder ↔ GC.malloc cycle)
#   - writing through abstract `IO` (pulls OpenSSL::SSL::Socket into codegen)
# Emit with LibC.write into a stack buffer + reentrancy guard.

require "c/unistd"
require "c/fcntl"

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
        fd = LibC.open(path, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_TRUNC, 0o644)
        if fd >= 0
          enable(fd, alloc_sample: sample, owned: true)
          return
        end
      end
      enable(2, alloc_sample: sample, owned: false)
    end

    def self.after_malloc(ptr : Void*, size : UInt64, atomic : Bool) : Nil
      return unless @@enabled
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

    def self.after_free(ptr : Void*) : Nil
      return unless @@enabled
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
        LibC.close(@@fd)
      end
      @@owned_fd = false
    end

    private def self.with_emit(event : String, & : UInt8*, Int32 -> Int32) : Nil
      return if @@emitting
      @@emitting = true
      begin
        buf = StaticArray(UInt8, 1024).new(0_u8)
        len = 0
        len = append_raw(buf.to_unsafe, len, "{\"event\":\"")
        len = append_raw(buf.to_unsafe, len, event)
        len = append_raw(buf.to_unsafe, len, "\",\"ts_ns\":")
        len = append_i64_value(buf.to_unsafe, len, Time.monotonic.total_nanoseconds.to_i64)
        len = yield buf.to_unsafe, len
        len = append_raw(buf.to_unsafe, len, "}\n")
        LibC.write(@@fd, buf.to_unsafe, LibC::SizeT.new(len)) if len > 0
      ensure
        @@emitting = false
      end
    end

    private def self.append_raw(buf : UInt8*, len : Int32, s : String) : Int32
      bytes = s.to_slice
      n = bytes.size
      return len if len + n > 1023
      n.times { |i| buf[len + i] = bytes[i] }
      len + n
    end

    private def self.append_ptr(buf : UInt8*, len : Int32, ptr : Void*) : Int32
      len = append_raw(buf, len, ",\"ptr\":\"0x")
      len = append_hex(buf, len, ptr.address)
      append_raw(buf, len, "\"")
    end

    private def self.append_str(buf : UInt8*, len : Int32, key : String, value : String) : Int32
      len = append_raw(buf, len, ",\"")
      len = append_raw(buf, len, key)
      len = append_raw(buf, len, "\":\"")
      len = append_raw(buf, len, value)
      append_raw(buf, len, "\"")
    end

    private def self.append_u64(buf : UInt8*, len : Int32, key : String, value : UInt64) : Int32
      len = append_raw(buf, len, ",\"")
      len = append_raw(buf, len, key)
      len = append_raw(buf, len, "\":")
      append_u64_value(buf, len, value)
    end

    private def self.append_bool(buf : UInt8*, len : Int32, key : String, value : Bool) : Int32
      len = append_raw(buf, len, ",\"")
      len = append_raw(buf, len, key)
      len = append_raw(buf, len, "\":")
      append_raw(buf, len, value ? "true" : "false")
    end

    private def self.append_u64_value(buf : UInt8*, len : Int32, value : UInt64) : Int32
      if value == 0
        return append_raw(buf, len, "0")
      end
      tmp = StaticArray(UInt8, 20).new(0_u8)
      i = 0
      v = value
      while v != 0 && i < 20
        tmp[i] = ('0'.ord + (v % 10)).to_u8
        v //= 10
        i += 1
      end
      return len if len + i > 1023
      while i > 0
        i -= 1
        buf[len] = tmp[i]
        len += 1
      end
      len
    end

    private def self.append_i64_value(buf : UInt8*, len : Int32, value : Int64) : Int32
      if value < 0
        len = append_raw(buf, len, "-")
        append_u64_value(buf, len, (-value).to_u64)
      else
        append_u64_value(buf, len, value.to_u64)
      end
    end

    private def self.append_hex(buf : UInt8*, len : Int32, value : UInt64) : Int32
      if value == 0
        return append_raw(buf, len, "0")
      end
      tmp = StaticArray(UInt8, 16).new(0_u8)
      i = 0
      v = value
      while v != 0 && i < 16
        nibble = (v & 0xf).to_u8
        tmp[i] = nibble < 10 ? ('0'.ord + nibble).to_u8 : ('a'.ord + nibble - 10).to_u8
        v >>= 4
        i += 1
      end
      return len if len + i > 1023
      while i > 0
        i -= 1
        buf[len] = tmp[i]
        len += 1
      end
      len
    end
  end
end

Gcry::Trace.init_from_env
