require "./spec_helper"

# The unmap guard's and the release ledger's records, the release map and the
# release quarantine are mapped when their knob is armed, not carried inside
# the heap. As `StaticArray`s they were 472 KiB of a 556 KiB `Heap`, and
# Crystal clears an instance when it allocates it, so every process had them
# resident from boot whether or not a knob was on
# (`bench/log/linux/2026-10-17-kemal-rss/`).
describe "research tables" do
  it "are not part of the heap object" do
    instance_sizeof(Gcry::Heap).should be < 128 * 1024
  end

  it "record a release once the ledger is armed" do
    heap = Gcry::Heap.new
    begin
      heap.large_cache_retain = 0_u64
      heap.large_recycle = false
      heap.guarded_release_at(0_u64).should be_nil
      heap.release_ledger = true
      heap.release_ledger?.should be_true
      heap.guard_slots_used.should eq 0_u64

      big = heap.malloc(1024 * 1024)
      base = big.address
      heap.free(big)
      heap.trim_large_cache(0_u64, defer: false)
      heap.guard_slots_used.should eq 1_u64
      record = heap.guarded_release_at(base).should_not be_nil
      record[1].should be >= 1024_u64 * 1024
      record[2].should eq Gcry::Heap::GUARD_KIND_LARGE
      heap.release_double.should eq 0_u64
    ensure
      heap.destroy
    end
  end

  it "quarantine a release once turned on" do
    heap = Gcry::Heap.new
    begin
      heap.large_cache_retain = 0_u64
      heap.large_recycle = false
      heap.release_quarantine = 2_u64
      heap.release_quarantine.should eq 2_u64

      big = heap.malloc(1024 * 1024)
      heap.free(big)
      heap.trim_large_cache(0_u64, defer: false)
      heap.quarantined_releases.should eq 1_u64
      heap.quarantine_held.should eq 1_u64
    ensure
      heap.destroy
    end
  end
end
