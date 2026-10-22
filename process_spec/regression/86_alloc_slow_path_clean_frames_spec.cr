require "../../src/gcry"
require "spec"

# The frames an allocation-triggered collection runs on held whatever the
# stack had at their depth before. The allocation entry (`GC.malloc_atomic`,
# with `Heap#malloc_atomic` and the hit path inlined) called `allocate`
# itself, so its frame was live across the collection, and the slots only the
# hit path writes were not written on the way there. The conservative scan
# read them as roots. That is how the occupancy claim lowered crystal-metric
# RegexDna's peak by 19% without touching what RegexDna allocates: before it,
# `Heap#malloc_atomic`'s `0x58(%rsp)` held the dead `Fasta` (left there by
# `GC.realloc`'s push of a callee-saved register during the Fasta phase), and
# through it the 64 MiB output buffer, at three collections; the claim
# changed the inlining and the slot went away. On 0.39.0 the entry's slots
# held Knuckeotide's dead hash buffers instead
# (`bench/log/linux/2026-10-22-regexdna-peak/`).
#
# Now the slow path is two tail calls: the entry pops its frame and jumps to
# `Heap#allocate_entry`, which has no frame, zeroes the stack below its
# return address (`Roots.wipe_below_sp`) and jumps to `allocate_traced`. The
# slow path's frames and the collector's are built over zeros.
#
# This counts, at a collection an allocation triggers, the words between the
# allocating call and the collector's entry SP that still hold a pattern a
# deeper call wrote there just before: words no frame on the way wrote (the
# measure regression 79 bounds). The fixed arm must find none. The control
# arm (`slow_entry_wipe = false`: the tail calls without the wipe) must find
# some, or the fixed arm could pass on a layout where nothing is left to
# wipe; both run in this process, one after the other, from the same depth.
# Measured on x86-64 Linux, Crystal 1.21.0, `--release`: 13 on the tree
# before (the entry's frame, live across the collection), 2 in the control
# arm (slots of the frames built below it that they do not write), 0 fixed.
# It needs the release build's tail calls and the wipe's asm, so it runs as
# `make alloc-entry-frame` runs regression 79 (`--release`), on x86-64 and
# arm64 outside Windows, where the wipe is off; a debug build says it
# skipped. The control arm's count is the layout's, so only x86-64 Linux,
# where it was measured, requires it to be non-zero.

private STALE86_PATTERN   = 0x5a5a_c3c3_5a5a_c386_u64
private STALE86_WORDS     =                      1024
private STALE86_SKIP_MARK = "stale86: needs a --release build on x86-64 or arm64 outside Windows, skipped"

@[NoInline]
private def stale86_fill_below : Nil
  buf = uninitialized StaticArray(UInt64, STALE86_WORDS)
  STALE86_WORDS.times { |i| buf[i] = STALE86_PATTERN }
  # Keep the stores: the array is otherwise dead.
  asm("" :: "r"(buf.to_unsafe) : "memory" : "volatile")
end

# One allocation that collects, from the same depth as the fill.
@[NoInline]
private def stale86_alloc_collecting(sp_out : UInt64*) : Void*
  sp_out.value = Gcry::Roots.hardware_stack_pointer.address
  GC.malloc_atomic(LibC::SizeT.new(64))
end

# Pattern words in `[collect_entry_sp, caller SP)` at the collection, with the
# slow path's wipe on or off.
private def stale86_count(wipe : Bool) : Int32
  heap = Gcry.default_heap
  saved_threshold = heap.gc_threshold
  caller_sp = 0_u64
  stale = -1
  collections_before = heap.collections
  heap.slow_entry_wipe = wipe
  heap.post_stw_hook = ->(stage : Symbol) do
    if stage == :after_start_world && stale < 0
      h = Gcry.default_heap
      n = 0
      p = h.collect_entry_sp & ~7_u64
      while p < caller_sp
        n += 1 if Pointer(UInt64).new(p).value == STALE86_PATTERN
        p &+= 8
      end
      stale = n
    end
    nil
  end
  begin
    stale86_fill_below
    heap.gc_threshold = 1_u64
    stale86_alloc_collecting(pointerof(caller_sp))
  ensure
    heap.gc_threshold = saved_threshold
    heap.post_stw_hook = nil
    heap.slow_entry_wipe = true
  end
  heap.collections.should be > collections_before
  caller_sp.should_not eq(0)
  stale
end

describe "Regression: an allocation's slow path collects on frames built over zeros" do
  it "leaves no stale word between the allocation and the collector" do
    {% if flag?(:release) && (flag?(:x86_64) || flag?(:aarch64)) && !flag?(:win32) %}
      control = stale86_count(wipe: false)
      fixed = stale86_count(wipe: true)
      STDERR.puts "stale86: control #{control}, fixed #{fixed}"
      {% if flag?(:x86_64) && flag?(:linux) %}
        control.should be > 0
      {% end %}
      fixed.should eq(0)
    {% else %}
      STDERR.puts STALE86_SKIP_MARK
    {% end %}
  end
end
