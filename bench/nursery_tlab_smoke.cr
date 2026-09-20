# Single-thread process GC: nursery + TLAB + minor_collect.
#
# The defect this exists for: FREE-claim during minor cleared FREE on an
# *old* TLAB freelist node before the minor/old filter, leaving
# USED-unmarked for scrub to drop — silent old-freelist corruption.
# Skip that claim on old nodes; nursery nodes still claim.
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
#   GCRY_BITMAP_ALLOC=0 GCRY_TLAB_MINOR_FREE_OLD=1 bin/nursery_tlab_smoke --disabled
#
# Dropping `-Dgcry_block_headers` or `GCRY_BITMAP_ALLOC=0`: exit 64.
# Dropping the knob from `--disabled`: exit 64.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "nursery_tlab_smoke requires -Dgc_none (gcry as process GC)" %}
{% end %}

DISABLED = ARGV.includes?("--disabled")
FREE_OLD = ENV["GCRY_TLAB_MINOR_FREE_OLD"]? == "1"

if DISABLED && !FREE_OLD
  STDERR.puts "--disabled needs GCRY_TLAB_MINOR_FREE_OLD=1: without the pre-fix claim this arm would require an old FREE node to become USED while the skip is still in place."
  exit 64
end

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
if DISABLED && !heap.tlab_minor_free_old
  STDERR.puts "--disabled needs GCRY_TLAB_MINOR_FREE_OLD=1: the property is off, so the minor/old skip is still running."
  exit 64
end

puts "=== nursery + TLAB minor ==="
puts DISABLED ? "mode: disabled (GCRY_TLAB_MINOR_FREE_OLD=1, the pre-fix old FREE-claim)" : "mode: shipped (minor skips old FREE-claim)"
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

# Old FREE node on this frame during a minor. Shipped skips the claim;
# `--disabled` clears FREE and leaves USED-unmarked.
free_after = claim_probe(heap)
puts "  claim_probe: still_free=#{free_after} minors=#{heap.minor_collections} tlab_hits=#{heap.tlab_hits} tlab_refills=#{heap.tlab_refills}"

if DISABLED
  if free_after
    failures << "GCRY_TLAB_MINOR_FREE_OLD=1 but the old FREE node stayed FREE — the pre-fix claim did not run, so this arm cannot fail when the skip is restored"
  else
    puts "  PASS disabled claim: old FREE node is USED after minor"
  end
else
  unless free_after
    failures << "shipped minor claimed an old FREE node (USED-unmarked) — the skip is gone"
  else
    puts "  PASS shipped claim: old FREE node stayed FREE"
  end
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
  if DISABLED
    puts "ok — minor claims an old FREE node (USED-unmarked); unrooted nursery objects still vanish"
  else
    puts "ok — rooted TLAB objects survive minor, old FREE nodes stay FREE, unrooted nursery objects vanish"
  end
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end

# Promote via a minor (majors do not clear NURSERY), free, then minor
# again with `p` on this frame. Heap roots use a different source and
# would skip the TLAB claim path, so they only keep it alive for the
# promoting minor.
@[NoInline]
def claim_probe(heap : Gcry::Heap) : Bool
  p = GC.malloc(64)
  heap.add_root(p)
  heap.minor_collect(scan_stack: false)
  heap.delete_root(p)
  if Gcry::BlockHeader.nursery?(Gcry::BlockHeader.from_user(p))
    STDERR.puts "FAIL: plant is still nursery after a surviving minor — the old-node skip would not apply"
    exit 1
  end
  GC.free(p)
  unless Gcry::BlockHeader.free?(Gcry::BlockHeader.from_user(p))
    STDERR.puts "FAIL: GC.free did not leave the plant FREE"
    exit 1
  end
  heap.minor_collect(scan_stack: true)
  still_free = Gcry::BlockHeader.free?(Gcry::BlockHeader.from_user(p))
  # Keep `p` live across the collect so the compiler does not drop it
  # below the SP the scrub zeroes.
  LibC.write(2, pointerof(p), 0)
  still_free
end
