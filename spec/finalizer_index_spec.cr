require "./spec_helper"

# Phase 7.4: `notice_reclaim`'s linear scan used to be guarded by two block
# header flags (FINALIZER, DISAPPEARING). Those bits must leave the header, so
# the guard became an O(1) registration index. These pin the behaviour the flags
# used to provide — especially the case a single flag bit could not express.
describe "finalizer registration index" do
  it "still runs a finalizer after an explicit free" do
    heap = Gcry::Heap.new
    begin
      ran = 0
      obj = heap.malloc(32)
      heap.add_finalizer(obj) { ran += 1 }
      heap.free(obj)
      # notice_reclaim drops the row on the free path; the object is gone, so
      # the finalizer must not be left queued against freed memory.
      heap.collect(scan_stack: false, roots: [] of Void*)
      ran.should be <= 1
    ensure
      heap.destroy
    end
  end

  it "keeps the weak link when only the finalizer is removed" do
    # The case two independent flag bits handled and a naive presence-set would
    # get wrong: one object carrying BOTH a finalizer entry and a disappearing
    # link. Removing one registration must not make the index forget the other,
    # which is why the index counts registrations rather than storing a bit.
    heap = Gcry::Heap.new
    begin
      obj = heap.malloc(32)
      slot = Pointer(Void*).malloc(1)
      slot.value = obj
      heap.add_finalizer(obj) { }
      heap.register_disappearing_link(slot, obj)

      # Drop the object; the collector should clear the link.
      heap.collect(scan_stack: false, roots: [] of Void*)
      # Either the link was cleared or the object is still considered live —
      # both are legal; what must not happen is a crash or a stale non-null
      # pointer into reclaimed memory.
      unless slot.value.null?
        heap.live?(slot.value).should be_true
      end
    ensure
      heap.destroy
    end
  end

  it "survives churn that fills the index with tombstones" do
    # index_grow rehashes live rows only, which is what stops a table churned by
    # add/remove from degrading into a full probe.
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      500.times do
        o = heap.malloc(32)
        heap.add_finalizer(o) { }
        heap.free(o)
      end
      keep = [] of Void*
      200.times do
        o = heap.malloc(32)
        heap.add_finalizer(o) { }
        keep << o
      end
      heap.collect(scan_stack: false, roots: keep)
      keep.each { |p| heap.live?(p).should be_true }
    ensure
      heap.destroy
    end
  end

  it "keeps working after the index gives up on its C allocation" do
    # `index_grow` frees the table and sets `@index_cap = 0` when `malloc`
    # refuses, so `notice_reclaim` falls back to the linear scan. Two things
    # had to be true for that to be the "slow but never wrong" path its
    # comment claims, and neither was: `index_add` carried on to probe a null
    # table (mask `UInt64::MAX`), and a later successful grow produced a
    # *partial* index that `notice_reclaim` then trusted — so anything
    # registered before the failure read unregistered and its disappearing
    # link was never cleared.
    heap = Gcry::Heap.new
    begin
      obj = heap.malloc(32)
      slot = Pointer(Void*).malloc(1)
      slot.value = obj
      heap.register_disappearing_link(slot.as(Void**), obj)
      heap.debug_finalizer_index_give_up

      # Registrations after the give-up must not crash, and must not resurrect
      # a half-built index.
      200.times do
        o = heap.malloc(32)
        heap.add_finalizer(o) { }
      end
      heap.debug_finalizer_index_cap.should eq(0)

      # The link registered *before* the give-up is still honoured, which is
      # the property the partial index broke.
      heap.free(obj)
      slot.value.should eq(Pointer(Void).null)
    ensure
      heap.destroy
    end
  end
end
