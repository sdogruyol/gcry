{% skip_file unless flag?(:linux) %}
require "../../src/gcry"
require "spec"

# A large block recycled for an allocation of another size clears only the
# pages the old block's objects wrote, not all it reuses. A block the program
# frees with `GC.free` stays cached (`Heap#large_recycle_keep`), and the next
# large allocation that is not its exact size takes its pages through the
# recycler (`Heap#recycle_large_mapping`), which reported every byte it kept
# as dirty: `GC.malloc` wrote zeroes over all of it and faulted in each page
# the old block never touched. A loop freeing blocks of 16 sizes from 256 KiB
# to 1.7 MiB, writing one byte of each, took 600-880 ms against 60-76 ms
# before the blocks were kept, and 220-310 ms under Boehm.
#
# The signal is residency rather than time: right after `GC.malloc`, the new
# block holds no resident page the old block left untouched. The other
# examples hold the zeroing to its contract where the old block's pages are
# written, and where they were written and then swapped out. `MADV_PAGEOUT`
# leaves those in the swap cache, where `mincore` still counts them resident
# but pagemap's present bit does not: a clear that skipped every page not
# present would leave 0xAB there. Only a host with swap moves them out;
# elsewhere the example runs on resident pages.
#
# Collections are held off and the cache emptied first, as in
# `32_large_free_reuse_spec`, so the block freed here is the only one the
# recycler can take.

lib LibC
  fun mincore(addr : Void*, length : SizeT, vec : UInt8*) : Int
end

private UNTOUCHED_OLD_BYTES = 1024 * 1024
private UNTOUCHED_NEW_BYTES = 1536 * 1024
private MADV_PAGEOUT        = 21

private def untouched_page : UInt64
  LibC.sysconf(LibC::SC_PAGESIZE).to_u64
end

# Whole pages inside `[ptr, ptr + bytes)`.
private def untouched_pages(ptr : Void*, bytes : Int) : {Void*, UInt64}
  page = untouched_page
  lo = (ptr.address + page - 1) & ~(page - 1)
  hi = (ptr.address + bytes.to_u64) & ~(page - 1)
  {Pointer(Void).new(lo), hi > lo ? hi - lo : 0_u64}
end

private def resident_pages(ptr : Void*, bytes : Int) : Int32
  base, len = untouched_pages(ptr, bytes)
  n = (len // untouched_page).to_i32
  vec = Bytes.new(n)
  LibC.mincore(base, LibC::SizeT.new(len), vec.to_unsafe).should eq(0)
  vec.count { |b| (b & 1) != 0 }
end

# What `Heap#recycle_large_mapping` checks before it takes a cached chunk, so
# a run that made no recycle says which check refused it.
private def recycle_state(heap : Gcry::Heap) : String
  thread = Thread.current?.try(&.name) || "none"
  "large_recycle=#{heap.@large_recycle} large_free_bytes=#{heap.@large_free_bytes} " \
  "live_chunk_walk=#{heap.@live_chunk_walk} world_stopped=#{heap.@world_stopped} " \
  "collecting=#{heap.@collecting} incremental_marking=#{heap.@incremental_marking} " \
  "barrier=#{heap.@barrier_backend} quarantine=#{heap.@release_quarantine} " \
  "ledger=#{heap.@release_ledger} unmap_guard=#{heap.@unmap_guard} holders=#{heap.@release_holders} " \
  "thread=#{thread} " \
  "recycle_budget=#{heap.large_recycle_budget} cache_hits=#{heap.large_cache_hits}"
end

# `GC.malloc`s a block of `UNTOUCHED_NEW_BYTES` after `GC.free`ing one of
# `UNTOUCHED_OLD_BYTES` that `write` filled in, and answers it with the
# recycles the allocation made and its resident pages, counted before
# anything reads it (a read maps the zero page, which counts as resident),
# and what the recycler saw just before it.
private def recycled_after(write : Pointer(UInt8) ->) : {Pointer(UInt8), UInt64, Int32, String}
  heap = Gcry.default_heap
  GC.collect
  heap.trim_large_cache(0_u64, defer: false, cap: UInt64::MAX)
  GC.disable
  begin
    old = GC.malloc(LibC::SizeT.new(UNTOUCHED_OLD_BYTES)).as(UInt8*)
    write.call(old)
    GC.free(old.as(Void*))
    recycles = heap.large_recycles
    state = recycle_state(heap)
    fresh = GC.malloc(LibC::SizeT.new(UNTOUCHED_NEW_BYTES)).as(UInt8*)
    {fresh, heap.large_recycles - recycles, resident_pages(fresh.as(Void*), UNTOUCHED_NEW_BYTES), state}
  ensure
    GC.enable
  end
end

describe "a large block recycled for another size" do
  it "leaves the pages the old block never touched unfaulted" do
    fresh, recycles, resident, state = recycled_after(->(old : Pointer(UInt8)) { old[0] = 1_u8 })
    recycles.should eq(1), state
    # One page for the byte written and the chunk's headers, a few more for
    # a kernel that faults anonymous memory in larger folios. Clearing all it
    # kept made 256 of these 384 pages resident.
    resident.should be < 32
    fresh.to_slice(UNTOUCHED_NEW_BYTES).all?(&.zero?).should be_true
  end

  it "reads zeroes where the old block wrote" do
    fresh, recycles, resident, state = recycled_after(->(old : Pointer(UInt8)) {
      old.to_slice(UNTOUCHED_OLD_BYTES).fill(0xAB_u8)
      nil
    })
    recycles.should eq(1), state
    # The old block's pages, moved and cleared, not fresh ones.
    resident.should be >= UNTOUCHED_OLD_BYTES // untouched_page.to_i32 - 1
    fresh.to_slice(UNTOUCHED_NEW_BYTES).all?(&.zero?).should be_true
  end

  it "reads zeroes where the old block wrote and the pages were swapped out" do
    fresh, recycles, _, state = recycled_after(->(old : Pointer(UInt8)) {
      old.to_slice(UNTOUCHED_OLD_BYTES).fill(0xAB_u8)
      base, len = untouched_pages(old.as(Void*), UNTOUCHED_OLD_BYTES)
      LibC.madvise(base, LibC::SizeT.new(len), MADV_PAGEOUT)
      nil
    })
    recycles.should eq(1), state
    fresh.to_slice(UNTOUCHED_NEW_BYTES).all?(&.zero?).should be_true
  end
end
