require "./spec_helper"

class Gcry::Heap
  # The record a release of *user*'s large chunk would leave, taken with the
  # block still allocated: the guard's control arm. With the ledger armed and
  # the unmap guard off, `guard_release` only records, so the chunk stays
  # mapped and `destroy` takes it down as usual.
  def spec_record_live_large_release(user : Void*) : Nil
    chunk = chunk_for(user).not_nil!
    guard_release(chunk.address, chunk.value.mapped_bytes, GUARD_KIND_LARGE)
  end
end

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

  # `Blocks still allocated at release` for a large chunk is its block
  # header's FREE flag. It was read with `BlockHeader.free?`, which is
  # constant `false` under headerless, so every large release on the default
  # layout said 1 — the FREE chunk the cache trim gives back above included —
  # and the 2026-09-28 `dormant_flush` sighting read as a chunk released with
  # its block allocated (`bench/log/linux/2026-10-21-dormant-flush-sighting/`).
  # Fails on the headerless build before the fix: the freed arm read 1.
  it "record whether a released large block was still allocated" do
    heap = Gcry::Heap.new
    begin
      heap.large_cache_retain = 0_u64
      heap.large_recycle = false
      heap.release_ledger = true

      # Both mapped at once, so the kernel cannot hand the second the first's
      # range and the two records cannot answer for each other.
      freed = heap.malloc(64 * 1024)
      live = heap.malloc(64 * 1024)
      freed_base = freed.address
      heap.free(freed)
      heap.trim_large_cache(0_u64, defer: false)
      record = heap.guarded_release_at(freed_base).should_not be_nil
      record[2].should eq Gcry::Heap::GUARD_KIND_LARGE
      record[5].should eq 0

      heap.spec_record_live_large_release(live)
      record = heap.guarded_release_at(live.address).should_not be_nil
      record[2].should eq Gcry::Heap::GUARD_KIND_LARGE
      record[5].should eq 1
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
