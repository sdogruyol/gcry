# `Crystal.trace :gc` events for the process heap, the set `gc/boehm.cr` emits:
# `malloc`, `realloc`, `free` and the explicit `collect` come from the `GC`
# facade (`gc_override.cr`); the per-collection `collect`, `collect:mark`,
# `collect:sweep` and `heap_resize` come from the heap through here, because
# only the heap knows when an automatic cycle runs and where its phases begin.
# Boehm reports the same four from its collection-event and heap-resize
# callbacks, with the world stopped for the mark ones, which is where gcry
# reports them from too.
#
# Without `-Dtracing` every method below is an empty inlined body, so the call
# sites compile to nothing — the same bargain `Crystal.trace` itself makes.
#
# Under `-Dtracing` with `CRYSTAL_TRACE=gc`, `Crystal::Tracing.log` formats into
# a fixed stack buffer and `write`s it: it allocates nothing on the GC heap, so
# it is safe from inside the stopped world and from under the allocator's own
# locks, and it cannot recurse into `GC.malloc`. Timestamps are
# `Crystal::System::Time.ticks`, not `Gcry::Clock` — Linux `ticks` reads
# `CLOCK_BOOTTIME`, and a trace consumer lines gc events up against the other
# sections' on that clock.
#
# Library heaps (`Gcry::Heap.new`) do not report: the `gc` section describes
# the process's collector, which is what Boehm's events describe.
module Gcry
  module CrystalTrace
    {% if flag?(:tracing) %}
      # Start stamp for a traced span of *heap*'s work, or 0 when nothing will
      # be reported — `finish` keys on that.
      def self.start(heap : Heap) : UInt64
        return 0_u64 unless on?(heap)
        ::Crystal::System::Time.ticks
      end

      def self.finish(operation : String, start : UInt64) : Nil
        return if start == 0_u64
        ::Crystal.trace :gc, operation, start, duration: ::Crystal::System::Time.ticks &- start
      end

      # Boehm calls its heap-resize hook when the heap grows; so does gcry's
      # chunk mapping. *size* is the heap size after the growth.
      def self.heap_resize(heap : Heap, size : UInt64) : Nil
        return unless on?(heap)
        ::Crystal.trace :gc, "heap_resize", size: size
      end

      private def self.on?(heap : Heap) : Bool
        ::Crystal::Tracing.enabled?(:gc) && heap.same?(Gcry.default_heap?)
      end
    {% else %}
      @[AlwaysInline]
      def self.start(heap : Heap) : UInt64
        0_u64
      end

      @[AlwaysInline]
      def self.finish(operation : String, start : UInt64) : Nil
      end

      @[AlwaysInline]
      def self.heap_resize(heap : Heap, size : UInt64) : Nil
      end
    {% end %}
  end
end
