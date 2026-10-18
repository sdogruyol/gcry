# Counter wrapper for crystal-metric: prints the default heap's GC counters at
# exit. Built separately from the timing binaries (it shifts code placement).
require "gcry"

at_exit do
  h = Gcry.default_heap
  STDERR.print "GCSTATS"
  {% for name in %w(collections total_pause_ns pause_count realloc_in_place_grows realloc_in_place_bytes
                   realloc_moves large_cache_hits large_cache_misses chunk_unlinks unlink_walk_steps
                   large_reservations large_reserved_bytes large_reserve_failures unmapped_bytes
                   large_mapped_bytes heap_size total_bytes large_recycles emergency_collects) %}
    {% if Gcry::Heap.has_method?(name) %}
      STDERR.print " {{name.id}}=", h.{{name.id}}
    {% end %}
  {% end %}
  STDERR.print " os_mapped_bytes=", Gcry.os_mapped_bytes if Gcry.responds_to?(:os_mapped_bytes)
  STDERR.print "\n"
end

require "./metric"
