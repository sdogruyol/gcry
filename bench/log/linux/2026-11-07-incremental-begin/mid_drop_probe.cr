# Probe (needs `mid_drop_probe.diff` applied; copy to the tree's root and
# build with `-Dgc_none`). A cycle is open; the main thread's `collect`
# drops it inside the section (`abort_incremental`), and the probe hook,
# right after `@inc_active = false`, releases a second thread into
# `collect_a_little` and waits until that thread holds a ticket for the
# section. ARM=control sets `Heap.inc_begins_in_section = false`.
require "./src/gcry"

CHAIN = 20_000

class Gcry::Heap
  def probe_stack_size : Int32
    @mark_stack.size
  end
end

module Probe
  class_property head = Pointer(Void).null
  class_property sink = 0_u64
  @@armed = Atomic(Int32).new(0)
  @@go = Atomic(Int32).new(0)
  @@hook = StaticArray(Int32, 4).new(0)
  @@slice = StaticArray(Int32, 4).new(0)
  @@result = Atomic(Int32).new(0)

  def self.arm : Nil
    @@armed.set(1)
  end

  def self.hook : StaticArray(Int32, 4)
    @@hook
  end

  def self.slice : StaticArray(Int32, 4)
    @@slice
  end

  def self.result : Int32
    @@result.get
  end

  # Main thread, inside `abort_incremental`, holding the section.
  def self.mid_drop : Nil
    return unless @@armed.swap(0) == 1
    heap = Gcry.default_heap
    queued = heap.@post_stw_next
    @@go.set(1)
    deadline = Gcry::Clock.monotonic_ns &+ 10_000_000_000_u64
    loop do
      Atomic::Ops.fence(LLVM::AtomicOrdering::SequentiallyConsistent, false)
      if heap.@post_stw_next != queued
        @@hook[0] = 1
        break
      end
      break if Gcry::Clock.monotonic_ns > deadline
      Intrinsics.pause
    end
    Atomic::Ops.fence(LLVM::AtomicOrdering::SequentiallyConsistent, false)
    @@hook[1] = heap.@inc_active ? 1 : 0
    @@hook[2] = heap.@barrier_backend.mprotect? ? 1 : 0
    @@hook[3] = heap.probe_stack_size
  end

  # Second thread's slice, holding the section.
  def self.locked : Nil
    heap = Gcry.default_heap
    @@slice[0] = 1
    @@slice[1] = heap.@inc_active ? 1 : 0
    @@slice[2] = heap.@barrier_backend.mprotect? ? 1 : 0
    @@slice[3] = heap.probe_stack_size
  end

  def self.second : Nil
    until @@go.get == 1
      Intrinsics.pause
    end
    @@result.set(Gcry.default_heap.collect_a_little(Int32::MAX) ? 1 : 2)
  end
end

@[NoInline]
def build(heap : Gcry::Heap) : Nil
  head = Pointer(Void).null
  CHAIN.times do
    node = GC.malloc(16).as(Void**)
    node[0] = head
    head = node.as(Void*)
  end
  Probe.head = head
  heap.add_root(head)
end

@[NoInline]
def scrub : Nil
  buf = uninitialized StaticArray(UInt64, 8192)
  words = buf.to_unsafe
  8192.times { |i| words[i] = 0_u64 }
  Probe.sink = words[0] &+ words[8191]
end

def alive(heap : Gcry::Heap) : Int32
  node = Probe.head
  count = 0
  while count < CHAIN && !node.null? && heap.find_object(node)
    count += 1
    node = node.as(Void**)[0]
  end
  count
end

heap = Gcry.default_heap
heap.disable
heap.prefer_mprotect_barrier = true
control = ENV["ARM"]? == "control"
Gcry::Heap.inc_begins_in_section = !control
second = Thread.new { Probe.second }
build(heap)
scrub
heap.collect_a_little(0)
abort "no cycle on mprotect" unless heap.incremental_in_progress? && heap.barrier_backend_name == "mprotect"
Gcry::Heap.probe_mid_drop_hook = -> { Probe.mid_drop }
Gcry::Heap.inc_slice_locked_hook = -> { Probe.locked }
Probe.arm
heap.collect
after_open = heap.incremental_in_progress?
after_backend = heap.barrier_backend_name
after_stack = heap.probe_stack_size
second.join
h = Probe.hook
s = Probe.slice
puts "arm=#{control ? "control" : "fixed"} hook: ticket=#{h[0]} open=#{h[1]} mprotect=#{h[2]} stack=#{h[3]} | " \
     "after collect: open=#{after_open} backend=#{after_backend} stack=#{after_stack} | " \
     "slice: ran=#{s[0]} open=#{s[1]} mprotect=#{s[2]} stack=#{s[3]} result=#{Probe.result} | " \
     "chain alive #{alive(heap)}/#{CHAIN}"
