# gcry — a Crystal garbage collector
#
# Alternative to bdwgc. Integrate with:
#   require "gcry"  and  crystal build -Dgc_none
#
# See DESIGN.md and docs/INTEGRATION.md.
require "./gcry/heap"
require "./gcry/layout"

module Gcry
  VERSION = "0.6.0"

  struct PauseStats
    getter last_ns : UInt64
    getter max_ns : UInt64
    getter total_ns : UInt64
    getter count : UInt64
    getter p50_ns : UInt64
    getter p99_ns : UInt64

    def initialize(@last_ns : UInt64, @max_ns : UInt64, @total_ns : UInt64, @count : UInt64,
                   @p50_ns : UInt64 = 0_u64, @p99_ns : UInt64 = 0_u64)
    end
  end

  @@default_heap : Heap? = nil

  # Process-wide heap used by the module-level allocators.
  def self.default_heap : Heap
    @@default_heap ||= Heap.new
  end

  # Replace the default heap (mainly for tests). Destroys the previous one.
  def self.default_heap=(heap : Heap) : Heap
    @@default_heap.try(&.destroy)
    @@default_heap = heap
  end

  def self.malloc(size : Int) : Void*
    default_heap.malloc(size)
  end

  def self.malloc_atomic(size : Int) : Void*
    default_heap.malloc_atomic(size)
  end

  def self.realloc(pointer : Void*, size : Int) : Void*
    default_heap.realloc(pointer, size)
  end

  def self.free(pointer : Void*) : Nil
    default_heap.free(pointer)
  end

  def self.is_heap_ptr(pointer : Void*) : Bool
    default_heap.is_heap_ptr(pointer)
  end

  def self.collect(scan_stack : Bool = true, roots : Array(Void*)? = nil) : Nil
    default_heap.collect(scan_stack: scan_stack, roots: roots)
  end

  def self.minor_collect(scan_stack : Bool = true, roots : Array(Void*)? = nil) : Nil
    default_heap.minor_collect(scan_stack: scan_stack, roots: roots)
  end

  def self.collect_a_little(work_units : Int32 = Heap::DEFAULT_INCREMENTAL_WORK) : Bool
    default_heap.collect_a_little(work_units)
  end

  def self.pause_stats : PauseStats
    h = default_heap
    PauseStats.new(
      h.last_pause_ns,
      h.max_pause_ns,
      h.total_pause_ns,
      h.pause_count,
      h.pause_percentile_ns(50.0),
      h.pause_percentile_ns(99.0),
    )
  end

  def self.add_root(pointer : Void*) : Nil
    default_heap.add_root(pointer)
  end

  def self.enable : Nil
    default_heap.enable
  end

  def self.disable : Nil
    default_heap.disable
  end

  def self.live?(pointer : Void*) : Bool
    default_heap.live?(pointer)
  end

  def self.push_stack(stack_top : Void*, stack_bottom : Void*) : Nil
    default_heap.push_stack(stack_top, stack_bottom)
  end

  def self.before_collect(&block : -> Nil) : Nil
    default_heap.before_collect(&block)
  end

  def self.set_stackbottom(stack_bottom : Void*) : Nil
    default_heap.set_stackbottom(stack_bottom)
  end

  def self.current_thread_stack_bottom : {Void*, Void*}
    default_heap.current_thread_stack_bottom
  end

  def self.add_finalizer(object : Void*, callback : Finalizers::Callback) : Nil
    default_heap.add_finalizer(object, callback)
  end

  def self.add_finalizer(object : Void*, &block : Finalizers::Callback) : Nil
    default_heap.add_finalizer(object, &block)
  end

  def self.register_disappearing_link(link : Void**, object : Void* = Pointer(Void).null) : Nil
    default_heap.register_disappearing_link(link, object)
  end

  def self.lock_read : Nil
    default_heap.lock_read
  end

  def self.unlock_read : Nil
    default_heap.unlock_read
  end

  def self.lock_write : Nil
    default_heap.lock_write
  end

  def self.unlock_write : Nil
    default_heap.unlock_write
  end
end

{% if flag?(:gc_none) %}
  require "./gcry/gc_override"
{% end %}
