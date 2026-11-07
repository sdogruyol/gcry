# Probe for regression 1 (not a spec): a stale word in drift_cycle's own frame,
# in a slot the measured window writes, holding a dead finalizable graph.
#
# Cycle 1 finds the slots: the caller fills the stack below it with a sentinel,
# drift_cycle notes which of its own frame's words still hold the sentinel after
# the pre-baseline collections, and which of those changed by the end of the
# window. Cycle 2 runs from the same call site, so its frame is at the same
# address: the caller fills again, plants the root of a dead graph (a
# finalizable holder of N small objects) in each of those slots, and runs the
# cycle. Arms (PROBE1_ARM):
#   control   plant, then drift_cycle as committed before the fix
#   fixed     plant, then the caller zeroes the stack below it before the call
#   unplanted no plant (fill only)
require "../wt/src/gcry"

lib LibC
  fun dprintf(fd : Int, fmt : Char*, ...) : Int
end

PROBE1_N        =                      2000
PROBE1_SENTINEL = 0x5e57_1e57_0bad_f00d_u64

class Probe1Holder
  def initialize(@items : Array(Array(Int32)))
  end

  def finalize
    Probe1.finalized += 1
  end
end

module Probe1
  class_property root = Pointer(Void).null
  class_property window_slots = Pointer(UInt64).null
  class_property window_count = 0
  class_property pre_slots = Pointer(UInt64).null
  class_property pre_count = 0
  class_property learning = false
  class_property finalized = 0
  class_property caller_sp = 0_u64
end

@[NoInline]
private def probe1_scrub : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory" : "volatile")
end

@[NoInline]
private def probe1_fill : Nil
  buf = uninitialized StaticArray(UInt64, 2048)
  i = 0
  while i < buf.size
    buf.to_unsafe[i] = PROBE1_SENTINEL
    i += 1
  end
  asm("" :: "r"(buf.to_unsafe) : "memory" : "volatile")
end

@[NoInline]
private def probe1_make : Nil
  items = Array(Array(Int32)).new(PROBE1_N) { [1, 2] }
  h = Probe1Holder.new(items)
  Probe1.root = h.as(Void*)
end

# Writes the dead graph's root into every learned slot below this frame.
@[NoInline]
private def probe1_plant : Int32
  sp = 0_u64
  asm("movq %rsp, $0" : "=r"(sp))
  root = Probe1.root.address
  n = 0
  i = 0
  while i < Probe1.window_count
    at = Probe1.window_slots[i]
    if at > sp + 512
      Pointer(UInt64).new(at).value = root
      n += 1
    end
    i += 1
  end
  root = 0_u64
  n
end

# Runs the plant 8 KiB down, so its frame is below drift_cycle's and the
# drift_cycle's own pre-baseline scrub wipes whatever copies of the root the
# plant's frame keeps.
@[NoInline]
private def probe1_deep_plant : Int32
  buf = uninitialized StaticArray(UInt64, 1024)
  asm("" :: "r"(buf.to_unsafe) : "memory" : "volatile")
  probe1_plant
end

@[NoInline]
private def probe1_note_pre(frame_lo : UInt64) : Nil
  return unless Probe1.learning
  n = 0
  p = frame_lo
  while p < Probe1.caller_sp && n < 1024
    if Pointer(UInt64).new(p).value == PROBE1_SENTINEL
      Probe1.pre_slots[n] = p
      n += 1
    end
    p += 8
  end
  Probe1.pre_count = n
end

@[NoInline]
private def probe1_note_post : Nil
  return unless Probe1.learning
  n = 0
  i = 0
  while i < Probe1.pre_count
    at = Probe1.pre_slots[i]
    if Pointer(UInt64).new(at).value != PROBE1_SENTINEL
      Probe1.window_slots[n] = at
      n += 1
    end
    i += 1
  end
  Probe1.window_count = n
end

# The spec's drift_cycle at 374dd89e, plus the two notes and the SP read.
private def drift_cycle(heap, count : Int32) : Int64
  frame_lo = 0_u64
  asm("movq %rsp, $0" : "=r"(frame_lo))
  ptrs = Array(Pointer(Void)).new(count)
  probe1_scrub
  4.times { GC.collect }
  LibC.dprintf(2, "probe1 pre live=%llu fin=%d\n", Gcry.metrics(heap).live_objects, Probe1.finalized)
  probe1_note_pre(frame_lo)
  GC.disable
  begin
    baseline = Gcry.metrics(heap).live_objects
    count.times { ptrs << GC.malloc_atomic(32) }
    raise "short" unless Gcry.metrics(heap).live_objects >= baseline + count
  ensure
    GC.enable
  end

  ptrs.each { |p| GC.free(p) }
  ptrs.clear
  probe1_note_post

  4.times { GC.collect; LibC.dprintf(2, "probe1 post live=%llu fin=%d\n", Gcry.metrics(heap).live_objects, Probe1.finalized) }

  Gcry.metrics(heap).live_objects.to_i64 - baseline.to_i64
end

arm = ENV["PROBE1_ARM"]? || "control"
heap = Gcry.default_heap
Probe1.pre_slots = LibC.malloc(1024 * 8).as(UInt64*)
Probe1.window_slots = LibC.malloc(1024 * 8).as(UInt64*)
probe1_make
probe1_scrub

csp = 0_u64
asm("movq %rsp, $0" : "=r"(csp))
Probe1.caller_sp = csp

Probe1.learning = true
probe1_fill
d1 = drift_cycle(heap, 10_000)
Probe1.learning = false

probe1_fill
planted = arm == "unplanted" ? 0 : probe1_deep_plant
Probe1.root = Pointer(Void).null
probe1_scrub if arm == "fixed"
d2 = drift_cycle(heap, 10_000)
LibC.dprintf(2, "probe1 %s: learned %d window slots of %d unwritten at the baseline, planted %d; cycle1 drift=%lld cycle2 drift=%lld\n",
  arm.to_unsafe, Probe1.window_count, Probe1.pre_count, planted, d1, d2)
