require "./spec_helper"

describe "Gcry nursery (minor GC)" do
  it "reclaims unreachable nursery objects on minor_collect" do
    heap = Gcry::Heap.new
    begin
      heap.nursery_enabled = true
      heap.gc_threshold = UInt64::MAX
      heap.nursery_threshold = UInt64::MAX

      keep = heap.malloc(32)
      drop = heap.malloc(32)
      heap.add_root(keep)

      heap.minor_collect(scan_stack: false)
      heap.live?(keep).should be_true
      heap.live?(drop).should be_false
      heap.minor_collections.should eq(1)
      # Survivor was promoted out of the nursery.
      Gcry::BlockHeader.nursery?(Gcry::BlockHeader.from_user(keep)).should be_false
    ensure
      heap.destroy
    end
  end

  it "keeps nursery objects reachable from old objects" do
    heap = Gcry::Heap.new
    begin
      heap.nursery_threshold = UInt64::MAX
      heap.gc_threshold = UInt64::MAX

      parent = heap.malloc(16)
      heap.add_root(parent)
      heap.minor_collect(scan_stack: false)
      Gcry::BlockHeader.nursery?(Gcry::BlockHeader.from_user(parent)).should be_false

      child = heap.malloc(32)
      parent.as(Void**).value = child

      heap.minor_collect(scan_stack: false)
      heap.live?(child).should be_true
    ensure
      heap.destroy
    end
  end

  it "triggers minor collect when nursery threshold is crossed" do
    heap = Gcry::Heap.new
    begin
      heap.nursery_threshold = 1024
      heap.gc_threshold = UInt64::MAX
      heap.add_root(heap.malloc(16))
      40.times { heap.malloc(64) }
      heap.minor_collections.should be > 0
    ensure
      heap.destroy
    end
  end
end

describe "Gcry incremental mark" do
  it "completes a cycle across collect_a_little slices" do
    heap = Gcry::Heap.new
    begin
      heap.nursery_enabled = false # force old-space alloc for a denser graph
      heap.gc_threshold = UInt64::MAX
      root = heap.malloc(64)
      heap.add_root(root)
      100.times do
        n = heap.malloc(32)
        # hang off root loosely via root payload slots when possible
      end

      finished = false
      10_000.times do
        finished = heap.collect_a_little(32)
        break if finished
      end
      finished.should be_true
      heap.major_collections.should be > 0
      heap.live?(root).should be_true
    ensure
      heap.destroy
    end
  end
end
