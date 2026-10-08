# Single-thread process GC: nursery + TLAB + minor_collect.
#
# A FREE block that a stack word happens to point at must stay FREE
# through a minor and through a major. The marker used to "claim" such a
# block: clear FREE and mark its `next_free` chain, on the theory that a
# mutator could be stopped holding FREE nodes out of its TLAB. First the
# claim was found to corrupt old freelists during a minor (it cleared FREE
# and then skipped the mark, leaving USED-unmarked for scrub to drop), and
# was skipped there. Since 2026-09-27 no mutator can be stopped holding
# such a node at all: the collector takes every TLAB slot lock before it
# stops the world, and a refill that a stop overtakes is discarded by its
# epoch. The claim was removed on 2026-09-28, so a FREE node on the stack
# is now a stale word like any other.
#
# Until 2026-09-20 CI built this headerless. `nursery_enabled=` is a
# no-op there, `tlab_enabled=` is refused (the bitmap allocator is
# forced, and TLAB is freelist-shaped), and `minor_collect` returns
# immediately. Twenty rooted objects surviving a no-op is not a gate.
# TLAB also cannot be turned on after the process heap has mapped
# bitmap chunks, so green requires `GCRY_BITMAP_ALLOC=0` at start.
#
#   crystal build -Dgc_none -Dgcry_block_headers bench/nursery_tlab_smoke.cr -o bin/nursery_tlab_smoke
#   GCRY_BITMAP_ALLOC=0 bin/nursery_tlab_smoke
#
# Dropping `-Dgcry_block_headers` or `GCRY_BITMAP_ALLOC=0`: exit 64.
# Restoring the claim fails the major probe; restoring it for old nodes
# during a minor fails the minor probe.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "nursery_tlab_smoke requires -Dgc_none (gcry as process GC)" %}
{% end %}

heap = Gcry.default_heap

unless heap.stop_the_world
  STDERR.puts "FAIL: process heap stop_the_world is false"
  exit 1
end

if heap.bitmap_alloc?
  STDERR.puts "nursery_tlab_smoke needs GCRY_BITMAP_ALLOC=0: TLAB is refused under the bitmap allocator (the process default)."
  exit 64
end

heap.tlab_enabled = true
heap.nursery_enabled = true
heap.nursery_threshold = UInt64::MAX
heap.gc_threshold = UInt64::MAX
heap.adaptive_nursery = false

unless heap.nursery_enabled
  STDERR.puts "nursery did not enable (headerless compile default, or GCRY_DISABLE_NURSERY). Build with -Dgcry_block_headers."
  exit 64
end
unless heap.tlab_enabled?
  STDERR.puts "tlab did not enable (bitmap_alloc still on, or headerless). Run with GCRY_BITMAP_ALLOC=0 on -Dgcry_block_headers."
  exit 64
end

puts "=== nursery + TLAB minor ==="
puts "bitmap_alloc=#{heap.bitmap_alloc?} tlab=#{heap.tlab_enabled?} nursery=#{heap.nursery_enabled} stw=#{heap.stop_the_world}"
puts ""

failures = [] of String

ptrs = [] of Void*
20.times { ptrs << GC.malloc_atomic(64) }
ptrs.each { |p| heap.add_root(p) }

if heap.tlab_hits == 0 && heap.tlab_refills == 0
  failures << "TLAB allocated nothing (hits=0 refills=0) — tlab_enabled is set but the alloc path did not take it"
end

10.times do |n|
  heap.minor_collect
  ptrs.each_with_index do |p, i|
    unless heap.live?(p)
      failures << "minor #{n} swept rooted TLAB object #{i}"
      break
    end
  end
end

# A FREE node on this frame, through a minor and then through a major.
minor_free, major_free = claim_probe(heap)
puts "  claim_probe: free_after_minor=#{minor_free} free_after_major=#{major_free} minors=#{heap.minor_collections} tlab_hits=#{heap.tlab_hits} tlab_refills=#{heap.tlab_refills}"
if minor_free
  puts "  PASS minor left the FREE node on the stack FREE"
else
  failures << "a minor claimed an old FREE node on the stack (USED-unmarked, dropped by scrub)"
end
if major_free
  puts "  PASS major left the FREE node on the stack FREE"
else
  failures << "a major claimed a FREE node on the stack: the TLAB on-stack-freelist claim is back"
end

# A promoted block freed in its nursery chunk, then a major.
#
# Linux must release the chunk. Accepting a kept chunk everywhere (as from
# 2026-10-05 until 2026-10-06) let the stale-node arm go vacuous unseen: a
# Linux major that stopped releasing would have printed the kept-chunk PASS
# and the freelist walk would have checked nothing that could dangle. macOS
# keeps the chunk, so there only the old-list arm can speak.
stale, released, on_old = released_chunk_probe(heap)
if stale > 0
  failures << "#{stale} freelist node(s) point into a released chunk: a promoted block freed in a nursery chunk " \
              "went on the old list, which the chunk's release does not rebuild"
elsif on_old
  failures << "the freed promoted block is on the old list although its chunk is a nursery chunk; " \
              "releasing that chunk would leave the node dangling"
elsif released
  puts "  PASS no freelist node points into the released chunk"
else
  {% if flag?(:linux) %}
    failures << "the major kept the probe's emptied chunk, which Linux releases, so the stale-node check above " \
                "walked lists that could not dangle"
  {% else %}
    puts "  PASS the freed promoted block is not on the old list (the major kept its chunk)"
  {% end %}
end

# Minor actually collected: an unrooted nursery object must vanish. A
# leftover word on this frame is not a root (`scan_stack: false`).
young = GC.malloc(64)
young_addr = young.address
young = Pointer(Void).null
heap.clear_stack(1_u64 << 20)
minors_before = heap.minor_collections
heap.minor_collect(scan_stack: false)
unless heap.minor_collections > minors_before
  failures << "minor_collect did not count a minor — nursery is on but the collection did not run"
end
if heap.live?(Pointer(Void).new(young_addr))
  failures << "unrooted nursery object survived minor — minor_collect is a no-op, or the stack still held it"
else
  puts "  PASS unrooted nursery object swept after minor"
end

if failures.empty?
  puts
  puts "ok — rooted TLAB objects survive minor, FREE nodes on the stack stay FREE, unrooted nursery objects vanish"
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end

# Promote via a minor (majors do not clear NURSERY), free, then collect
# with `p` on this frame: a minor, then a major. Heap roots use a
# different source than the stack, so they only keep the plant alive for
# the promoting minor.
#
# `keep` is the plant's chunk-mate, rooted throughout. Without it the major
# finds the chunk empty and releases it, and the read of `p`'s header below
# faults: until 2026-10-05 the twenty 64-byte atomic plants in `main` shared
# this class and kept the chunk, and the atomic slack moved them one class up.
@[NoInline]
def claim_probe(heap : Gcry::Heap) : {Bool, Bool}
  p = GC.malloc(64)
  keep = GC.malloc(64)
  heap.add_root(keep)
  heap.add_root(p)
  heap.minor_collect(scan_stack: false)
  heap.delete_root(p)
  if Gcry::BlockHeader.nursery?(Gcry::BlockHeader.from_user(p))
    STDERR.puts "FAIL: plant is still nursery after a surviving minor, so the minor probe would test a nursery node"
    exit 1
  end
  GC.free(p)
  unless Gcry::BlockHeader.free?(Gcry::BlockHeader.from_user(p))
    STDERR.puts "FAIL: GC.free did not leave the plant FREE"
    exit 1
  end
  heap.minor_collect(scan_stack: true)
  after_minor = Gcry::BlockHeader.free?(Gcry::BlockHeader.from_user(p))
  heap.collect(scan_stack: true)
  unless heap.is_heap_ptr(p)
    STDERR.puts "FAIL: the major released the plant's chunk although `keep` shares it, so its header cannot be read"
    exit 1
  end
  after_major = Gcry::BlockHeader.free?(Gcry::BlockHeader.from_user(p))
  heap.delete_root(keep)
  # Keep `p` live across both collections so the compiler does not drop it
  # below the SP the scrub zeroes.
  LibC.write(2, pointerof(p), 0)
  {after_minor, after_major}
end

RELEASE_PROBE_SIZE = 1000

# A size class nothing else here allocates, so the plant is alone in its
# nursery chunk. Promote it, free it, and run a major. Before 2026-10-05
# `GC.free` chose the list by the block's NURSERY bit: a promoted block went
# on the old list, a release rebuilt only the nursery list (the chunk's), and
# the next allocation of that class wrote into unmapped memory. Linux releases
# the emptied chunk here, so every node on both lists must still be in the
# heap; macOS keeps it, so the plant must at least not be on the old list.
@[NoInline]
def released_chunk_probe(heap : Gcry::Heap) : {Int32, Bool, Bool}
  q = GC.malloc(RELEASE_PROBE_SIZE)
  heap.add_root(q)
  heap.minor_collect(scan_stack: false)
  heap.delete_root(q)
  if Gcry::BlockHeader.nursery?(Gcry::BlockHeader.from_user(q))
    STDERR.puts "FAIL: the release probe's plant is still nursery after a surviving minor"
    exit 1
  end
  GC.free(q)
  heap.collect(scan_stack: true)
  released = !heap.is_heap_ptr(q)
  _, class_index = Gcry::SizeClasses.fit(RELEASE_PROBE_SIZE.to_u64)
  stale = 0
  on_old = false
  {heap.freelist_for(class_index), heap.nursery_freelist_for(class_index)}.each_with_index do |head, list|
    node = head
    steps = 0
    while !node.null? && steps < 100_000
      unless heap.is_heap_ptr(node)
        stale += 1
        break
      end
      on_old = true if list == 0 && node == q
      node = Gcry::BlockHeader.from_user(node).value.next_free
      steps += 1
    end
  end
  {stale, released, on_old}
end
