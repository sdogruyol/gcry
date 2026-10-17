# crystal-metric's Binarytrees (n = 18, the same trees in the same order),
# with the time spent building trees and walking them (`check`) taken apart,
# and the collector's counters at the end. Three clock reads per tree (1.4 M
# trees) are in `total_ms` and not in either part. Build it next to a
# `lib/gcry/src` like crystal-metric (probe.sh).
{% if flag?(:gc_none) %}
  require "gcry"
{% end %}

class TreeNode
  property left : TreeNode?
  property right : TreeNode?
  property item : Int32

  def self.create(item, depth) : TreeNode
    TreeNode.new item, depth - 1
  end

  def initialize(@item, depth = 0)
    if depth > 0
      self.left = TreeNode.new 2 * item - 1, depth - 1
      self.right = TreeNode.new 2 * item, depth - 1
    end
  end

  def check
    return item if (lft = left).nil?
    return item if (rgt = right).nil?
    lft.check - rgt.check + item
  end
end

# A method, as `Binarytrees#run` is: its `long_lived_tree` is never read
# again, so the optimiser drops it and neither collector sees it live — the
# live set stays near zero. Reading it at the end (the first cut of this
# file did) kept 16 MiB live and tripled the mark work.
def run_bt(n : Int32) : {Int32, Time::Span, Time::Span}
  build = Time::Span.zero
  walk = Time::Span.zero
  result = 0
  min_depth = 4
  max_depth = Math.max min_depth + 2, n
  t = Time.instant
  stretch = TreeNode.create(0, max_depth + 1)
  build += Time.instant - t
  t = Time.instant
  result += stretch.check
  walk += Time.instant - t
  t = Time.instant
  long_lived_tree = TreeNode.create 0, max_depth
  build += Time.instant - t
  min_depth.step(to: max_depth, by: 2) do |depth|
    iterations = 1 << (max_depth - depth + min_depth)
    1.upto(iterations) do |i|
      {i, -i}.each do |item|
        t = Time.instant
        tree = TreeNode.create(item, depth)
        t2 = Time.instant
        result += tree.check
        walk += Time.instant - t2
        build += t2 - t
      end
    end
  end
  {result, build, walk}
end

t_all = Time.instant
result, build, walk = run_bt((ARGV[0]? || "18").to_i)
total = Time.instant - t_all
arm = {{ flag?(:gc_none) ? "gcry" : "boehm" }}
line = "BT #{arm} result=#{result} total_ms=#{total.total_milliseconds.round(1)} build_ms=#{build.total_milliseconds.round(1)} walk_ms=#{walk.total_milliseconds.round(1)}"
{% if flag?(:gc_none) %}
  h = Gcry.default_heap
  line += " majors=#{h.major_collections} pause_ms=#{(h.total_pause_ns / 1e6).round(1)} max_pause_ms=#{(h.max_pause_ns / 1e6).round(2)}" \
          " threshold=#{h.gc_threshold} hits=#{h.cursor_hit_allocations} locked=#{h.bitmap_locked_allocations}" \
          " refills=#{h.bitmap_alloc_refills} word_adv=#{h.cursor_word_advances} miss_coll=#{h.fast_miss_collecting}" \
          " miss_refill=#{h.fast_miss_refill} miss_thr=#{h.fast_miss_threshold} miss_noset=#{h.fast_miss_no_set}" \
          " chunk_adv=#{h.bitmap_alloc_chunk_advances} revives=#{h.bitmap_dormant_revives} heap_size=#{h.heap_size}" \
          " chunks=#{h.size_class_chunk_count} small_mapped=#{h.small_mapped_bytes} dormant=#{h.dormant_chunk_bytes}"
{% else %}
  ps = GC.prof_stats
  line += " gc_no=#{ps.gc_no} markers=#{ps.markers_m1 + 1} heap_size=#{ps.heap_size} obtained=#{ps.obtained_from_os_bytes}"
{% end %}
puts line
