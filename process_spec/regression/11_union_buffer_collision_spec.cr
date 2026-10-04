require "../../src/gcry"
require "spec"
require "json"

# A buffer of mixed-union values starts with its first element's type id,
# which is what `Gcry::Layout` keyed a block's type off. Two shapes of
# `Array(JSON::Any)` buffer read as registered types in the right size class:
#
# - `[array, "x"]`: 32 bytes, read as an `Array(JSON::Any)` and scanned at
#   its one offset, which in the buffer is the second element's tag;
# - `[hash, nil, 1_i64, nil]`: 64 bytes, read as a `Hash(String, JSON::Any)`
#   that passed the shape check once `Int64`'s id is 256 or more, so the
#   first element was marked without being traced.
#
# Either way what the elements held was swept while the arrays still held it,
# and reading it back crashed (`bench/log/linux/2026-10-04-layout-union-collision/`).
#
# Built and read in frames that have returned before the example drops them,
# as in `10_monitor_wait_cpu_spec`: left reachable, they would be freed under
# `1_live_objects_dormant_spec`, which runs later and reads the drift.
UNION_COUNT = 5_000

@[NoInline]
def union_collision_churn : Nil
  3.times do
    GC.collect
    junk = Array(String).new
    50_000.times { |j| junk << "union-churn-#{j}-xxxxxxxxxxxxxxxx" }
  end
  GC.collect
end

@[NoInline]
def union_pairs_build(holder : Array(Array(JSON::Any))) : Nil
  UNION_COUNT.times do |i|
    inner = [JSON::Any.new("v#{i}")]
    holder << [JSON::Any.new(inner), JSON::Any.new("s#{i}")]
  end
end

@[NoInline]
def union_pairs_wrong(holder : Array(Array(JSON::Any))) : Int32
  wrong = 0
  holder.each_with_index do |pair, i|
    wrong += 1 unless pair[0].as_a[0].as_s == "v#{i}" && pair[1].as_s == "s#{i}"
  end
  wrong
end

@[NoInline]
def union_quads_build(holder : Array(JSON::Any)) : Nil
  UNION_COUNT.times do |i|
    head = JSON::Any.new({"k#{i}" => JSON::Any.new("v#{i}")})
    holder << JSON::Any.new([head, JSON::Any.new(nil), JSON::Any.new(i.to_i64), JSON::Any.new(nil)])
  end
end

@[NoInline]
def union_quads_wrong(holder : Array(JSON::Any)) : Int32
  wrong = 0
  holder.each_with_index do |quad, i|
    wrong += 1 unless quad[0]["k#{i}"].as_s == "v#{i}"
  end
  wrong
end

describe "Regression: union buffer type id collision" do
  it "keeps both elements of two-element JSON::Any arrays" do
    holder = Array(Array(JSON::Any)).new(UNION_COUNT)
    union_pairs_build(holder)
    union_collision_churn
    wrong = union_pairs_wrong(holder)
    holder.clear
    GC.collect
    wrong.should eq(0)
  end

  it "keeps the hash at the head of a four-element JSON::Any array" do
    holder = Array(JSON::Any).new(UNION_COUNT)
    union_quads_build(holder)
    union_collision_churn
    wrong = union_quads_wrong(holder)
    holder.clear
    GC.collect
    wrong.should eq(0)
  end
end
