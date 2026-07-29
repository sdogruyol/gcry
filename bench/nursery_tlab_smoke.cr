# Single-thread process GC: nursery + TLAB + minor_collect.
# Parallel+TLAB+minor still fails stw_mt_property_test (separate bug).
#
# crystal build -Dgc_none bench/nursery_tlab_smoke.cr -o bin/nursery_tlab_smoke
# ./bin/nursery_tlab_smoke

require "../src/gcry"

{% unless flag?(:gc_none) %}
  raise "nursery_tlab_smoke requires -Dgc_none"
{% end %}

Gcry.default_heap.tlab_enabled = true
Gcry.default_heap.nursery_enabled = true
Gcry.default_heap.nursery_threshold = UInt64::MAX
Gcry.default_heap.gc_threshold = UInt64::MAX

ptrs = [] of Void*
20.times { ptrs << GC.malloc_atomic(64) }
ptrs.each { |p| Gcry.default_heap.add_root(p) }
10.times do |n|
  Gcry.default_heap.minor_collect
  ptrs.each_with_index do |p, i|
    unless Gcry.default_heap.live?(p)
      STDERR.puts "FAIL minor #{n} root #{i}"
      exit 1
    end
  end
end
puts "OK"
