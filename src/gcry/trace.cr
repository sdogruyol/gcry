# GC event trace — NDJSON lines for debugging (Phase 7.1).
#
# Enable: `GCRY_TRACE=1`
# Optional: `GCRY_TRACE_FILE=/tmp/gcry.ndjson` (default: stderr)
# Alloc sampling: `GCRY_TRACE_ALLOC_SAMPLE=N` (default 1000 = 1/1000; 0 disables alloc lines)
#
# Collect/barrier/finalizer events always log when enabled.
# Alloc/free use a reentrancy guard so JSON formatting does not recurse into malloc.

require "json"

module Gcry
  module Trace
    @@enabled = false
    @@emitting = false
    @@io : IO? = nil
    @@alloc_sample = 1000_u64
    @@alloc_tick = Atomic(UInt64).new(0)

    def self.enabled? : Bool
      @@enabled
    end

    def self.enable(io : IO? = nil, alloc_sample : UInt64 = 1000_u64) : Nil
      @@io = io
      @@alloc_sample = alloc_sample
      @@enabled = true
    end

    def self.disable : Nil
      @@enabled = false
      @@io = nil
    end

    def self.init_from_env : Nil
      return unless ENV["GCRY_TRACE"]? == "1"

      sample = 1000_u64
      if s = ENV["GCRY_TRACE_ALLOC_SAMPLE"]?
        sample = s.to_u64? || 1000_u64
      end

      io : IO? = nil
      if path = ENV["GCRY_TRACE_FILE"]?
        io = File.open(path, "w")
      end
      enable(io, alloc_sample: sample)
    end

    def self.after_malloc(ptr : Void*, size : UInt64, atomic : Bool) : Nil
      return unless @@enabled
      return if ptr.null?
      return if @@alloc_sample == 0
      n = @@alloc_tick.add(1)
      return unless (n % @@alloc_sample) == 0
      emit("alloc") do |json|
        json.field "ptr", format_ptr(ptr)
        json.field "size", size
        json.field "atomic", atomic
      end
    end

    def self.after_free(ptr : Void*) : Nil
      return unless @@enabled
      return if ptr.null?
      return if @@alloc_sample == 0
      n = @@alloc_tick.add(1)
      return unless (n % @@alloc_sample) == 0
      emit("free") do |json|
        json.field "ptr", format_ptr(ptr)
      end
    end

    def self.collect_start(major : Bool) : Nil
      emit("collect_start") do |json|
        json.field "major", major
      end
    end

    def self.collect_end(heap : Heap, major : Bool) : Nil
      emit("collect_end") do |json|
        json.field "major", major
        json.field "collections", heap.collections
        json.field "live_objects", heap.live_objects
        json.field "heap_size", heap.heap_size
        json.field "pause_ns", heap.last_pause_ns
        json.field "mark_ns", heap.last_phase_mark_ns
        json.field "sweep_ns", heap.last_phase_sweep_ns
        json.field "roots_ns", heap.last_phase_roots_ns
      end
    end

    def self.barrier_arm(backend : String) : Nil
      emit("barrier_arm") do |json|
        json.field "backend", backend
      end
    end

    def self.finalizer(kind : String, object : Void*) : Nil
      emit("finalizer") do |json|
        json.field "kind", kind
        json.field "ptr", format_ptr(object)
      end
    end

    private def self.emit(event : String, & : JSON::Builder ->) : Nil
      return unless @@enabled
      return if @@emitting
      @@emitting = true
      begin
        io = @@io || STDERR
        JSON.build(io) do |json|
          json.object do
            json.field "event", event
            json.field "ts_ns", Time.monotonic.total_nanoseconds.to_i64
            yield json
          end
        end
        io << '\n'
        io.flush
      ensure
        @@emitting = false
      end
    end

    private def self.format_ptr(ptr : Void*) : String
      "0x#{ptr.address.to_s(16)}"
    end
  end
end

Gcry::Trace.init_from_env
