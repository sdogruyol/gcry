require "../../src/gcry"
require "spec"

# `GC.free` of an object that has a finalizer (default-path review).
#
# The free path queued the object's finalizer rows and then handed the block
# back to the allocator. The queue kept the raw address, so the next
# collection's `run_pending` ran the finalizer on whatever had reused the
# block. 2026-10-11, before the fix: a `#finalize` that marks its object
# closed, as `IO::FileDescriptor`'s does, ran on a live object of the same
# size that took the block 61 allocations later, read its field and
# overwrote it — an fd finalizer would close the new owner's descriptor. The
# C form (`GC_register_finalizer`, freed by `GC_realloc(p, 0)`) did the same.
# Boehm calls freeing a finalizable object a caller error; gcry now drops the
# rows on the free and runs nothing.
#
# Same size and kind as what reuses them, so the block comes back within the
# allocator's current word (60 to 63 allocations on a bitmap chunk, the next
# one on a freelist).

private REUSE_TRIES = 100_000

# Finalizer runs, in libc memory so counting allocates nothing.
private FREED_RUNS = LibC.malloc(sizeof(Int32)).as(Int32*)

private class FreedFinalizable
  @fd : Int32 = 7
  @state : Int32 = 1

  def finalize
    FREED_RUNS.value += 1
    @fd = -1
    @state = 0
  end
end

# `FreedFinalizable`'s layout and kind (12 bytes, no pointers), no finalizer.
private class FreedReuser
  getter fd : Int32 = 0x1111
  getter state : Int32 = 0x2222
end

private def collect_and_drain : Nil
  3.times { GC.collect }
  Gcry.default_heap.invoke_finalizers
end

describe "Regression: freeing a finalizable object" do
  it "drops #finalize on GC.free and leaves the object that reuses the block alone" do
    FREED_RUNS.value = 0
    heap = Gcry.default_heap
    entries = heap.finalizer_entry_count
    # Before the free: nothing between it and the reuse may allocate.
    keep = Array(FreedReuser).new(REUSE_TRIES)
    victim = FreedFinalizable.new
    address = victim.as(Void*)
    GC.free(address)
    REUSE_TRIES.times do
      keep << FreedReuser.new
      break if keep.last.as(Void*) == address
    end
    heap.finalizer_entry_count.should eq(entries)

    reuser = keep.last
    reuser.as(Void*).should eq(address)
    collect_and_drain
    FREED_RUNS.value.should eq(0)
    reuser.fd.should eq(0x1111)
    reuser.state.should eq(0x2222)
  end

  it "drops a GC_register_finalizer function on GC_realloc(p, 0)" do
    FREED_RUNS.value = 0
    heap = Gcry.default_heap
    entries = heap.finalizer_entry_count
    keep = Pointer(UInt64*).malloc(REUSE_TRIES)
    victim = LibGC.malloc(16)
    LibGC.register_finalizer(victim, ->(object : Void*, data : Void*) {
      data.as(Int32*).value += 1
      object.as(UInt64*).value = 0_u64
    }, FREED_RUNS.as(Void*), nil, nil)
    heap.finalizer_entry_count.should eq(entries + 1)
    LibGC.realloc(victim, 0).null?.should be_true
    found = -1
    REUSE_TRIES.times do |i|
      block = LibGC.malloc(16).as(UInt64*)
      block[0] = 0x3333_u64
      block[1] = 0x4444_u64
      keep[i] = block
      if block.as(Void*) == victim
        found = i
        break
      end
    end
    heap.finalizer_entry_count.should eq(entries)

    found.should be >= 0
    collect_and_drain
    FREED_RUNS.value.should eq(0)
    keep[found][0].should eq(0x3333_u64)
    keep[found][1].should eq(0x4444_u64)
  end
end
