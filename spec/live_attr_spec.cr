require "./spec_helper"
require "json"

describe "Gcry.live_attr_json" do
  it "aggregates live objects by size class and type_id" do
    heap = Gcry::Heap.new
    begin
      heap.live_attr_roots = true
      roots = [] of Void*
      4.times do
        p = heap.malloc(48)
        heap.add_root(p)
        roots << p
      end
      big = heap.malloc(64)
      heap.add_root(big)
      heap.collect

      obj = JSON.parse(Gcry.live_attr_json(heap, top_n: 8))
      obj["total_objects"].as_i.should be >= 5
      obj["total_bytes"].as_i.should be > 0
      obj["live_attr_roots"].as_bool.should be_true
      # Explicit add_root uses Stack source → first-mark stack non-zero.
      obj["first_mark_stack_objects"].as_i.should be > 0
      obj["first_mark_stack_bytes"].as_i.should be > 0
      obj["collision_bytes"]?.should_not be_nil
      obj["max_size_class"]?.should_not be_nil

      classes = obj["size_classes"].as_a
      classes.size.should be > 0
      bytes_sum = classes.sum(&.["bytes"].as_i64)
      bytes_sum.should be > 0
    ensure
      heap.destroy
    end
  end

  it "classifies oversized type_id-looking blocks as collision" do
    heap = Gcry::Heap.new
    begin
      # 4 KiB block with a plausible type_id word at [0] but not a real header.
      p = heap.malloc(4096)
      p.as(Int32*).value = 42
      heap.add_root(p)
      heap.collect

      obj = JSON.parse(Gcry.live_attr_json(heap))
      obj["collision_objects"].as_i.should be >= 1
      obj["collision_bytes"].as_i64.should be >= 4096
    ensure
      heap.destroy
    end
  end
end
