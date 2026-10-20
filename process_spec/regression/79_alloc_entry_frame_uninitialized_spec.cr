require "../../src/gcry"
require "spec"

# The allocation entry carried 512 bytes of stack that nothing writes.
# `GC.malloc` and `GC.malloc_atomic` inline `check_fork_poison!`, and its
# message buffer (`uninitialized UInt8[RawOut::LIMIT]`) sat in their frame.
# That frame is live across every collection an allocation triggers, above
# `collect_entry_sp`, so the conservative scan read the buffer as roots.
# Whatever deeper calls had left at that depth was kept alive. On
# crystal-metric JsonParsePull, built with the occupancy claim, which inlines
# `Heap#malloc_atomic` into `GC.malloc_atomic`, one such slot held a dead
# 33.5 MB `IO::Memory` buffer through one more collection. The large cache
# then recycled a different mapping, and the run unmapped and faulted again
# 25 MB more than base: +4.8% page faults, +1.3% peak
# (`bench/log/linux/2026-10-19-occupancy-claim-038/`).
#
# A conservative scan cannot tell a stale slot from a live one, so this does
# not test retention. It counts, at a collection an allocation triggers, the
# stack words between the allocating call and the collector's entry SP that
# still hold a pattern written there just before by a deeper call. Those are
# words no frame on the allocation path wrote. With the buffer inline, at
# least 64 of them survive. Without it, only the slots a frame skips.
# Measured on x86-64 Linux, Crystal 1.21.0: built `--release`, 73 survive
# with the buffer inline (this fails) and 13 without. A debug build inlines
# nothing, so the buffer has its own frame and both read 21: only the
# release build tells the two apart, and `make alloc-entry-frame` runs this
# spec that way.

private STALE_PATTERN = 0x5a5a_c3c3_5a5a_c3c3_u64
private STALE_WORDS   =                      1024

# Fill the stack below the caller's frame with the pattern.
@[NoInline]
private def stale_fill_below : Nil
  buf = uninitialized StaticArray(UInt64, STALE_WORDS)
  STALE_WORDS.times { |i| buf[i] = STALE_PATTERN }
  # Keep the stores: the array is otherwise dead.
  asm("" :: "r"(buf.to_unsafe) : "memory" : "volatile")
end

# One allocation that collects, from the same depth as the fill.
@[NoInline]
private def stale_alloc_collecting(sp_out : UInt64*) : Void*
  sp_out.value = Gcry::Roots.hardware_stack_pointer.address
  GC.malloc_atomic(LibC::SizeT.new(64))
end

describe "Regression: the allocation entry's frame holds no unwritten buffer" do
  it "leaves under 64 stale words between the allocation and the collector" do
    heap = Gcry.default_heap
    saved_threshold = heap.gc_threshold
    caller_sp = 0_u64
    stale = -1
    collections_before = heap.collections
    heap.post_stw_hook = ->(stage : Symbol) do
      if stage == :after_start_world && stale < 0
        h = Gcry.default_heap
        n = 0
        p = h.collect_entry_sp & ~7_u64
        while p < caller_sp
          n += 1 if Pointer(UInt64).new(p).value == STALE_PATTERN
          p &+= 8
        end
        stale = n
      end
      nil
    end
    begin
      stale_fill_below
      heap.gc_threshold = 1_u64
      stale_alloc_collecting(pointerof(caller_sp))
    ensure
      heap.gc_threshold = saved_threshold
      heap.post_stw_hook = nil
    end
    heap.collections.should be > collections_before
    caller_sp.should_not eq(0)
    stale.should be >= 0
    stale.should be < 64
  end
end
