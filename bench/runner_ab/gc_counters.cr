# Prints the default heap's counters at exit, for `AB_STATS` in
# bench/runner_ab/ab.sh, which puts this file in front of the entry file of a
# counter build (`COUNTERS=1`: crystal-metric's `main.cr`, Kemal's
# `server.cr`). One `GCSTATS name=value ...` line on stderr. A counter an
# older revision lacks is left out rather than failing the build, so `base`
# can be any release this harness measures against. Kemal stops on SIGTERM and
# returns from `Kemal.run`, so the hook runs there too.
#
# Built apart from the timing binaries: the extra code moves where the rest
# lands, and the counters, unlike the time, don't depend on that.
require "gcry"

at_exit do
  h = Gcry.default_heap
  STDERR.print "GCSTATS"
  {% for name in %w(collections total_pause_ns max_pause_ns pause_count
                   realloc_in_place_grows realloc_in_place_bytes realloc_moves
                   large_cache_hits large_cache_misses large_recycles
                   chunk_unlinks unlink_walk_steps
                   large_reservations large_reserved_bytes large_reserve_failures
                   large_mapped_bytes unmapped_bytes dontneed_bytes page_release_bytes
                   heap_size total_bytes emergency_collects) %}
    {% if Gcry::Heap.has_method?(name) %}
      STDERR.print " {{name.id}}=", h.{{name.id}}
    {% end %}
  {% end %}
  STDERR.print " os_mapped_bytes=", Gcry.os_mapped_bytes if Gcry.responds_to?(:os_mapped_bytes)
  STDERR.print "\n"
end
