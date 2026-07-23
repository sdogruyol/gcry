# gcry — a Crystal garbage collector
#
# Alternative to bdwgc. Integrate like ysbaddaden/gc (immix):
#   require "gcry"  and  crystal build -Dgc_none
#
# See DESIGN.md and docs/INTEGRATION.md.
require "./gcry/heap"

module Gcry
  VERSION = "0.1.0"

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
end

# Phase 4+: reopen ::GC here under flag?(:gc_none) and forward to Gcry::*.
