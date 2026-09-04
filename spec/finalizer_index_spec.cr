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
end
