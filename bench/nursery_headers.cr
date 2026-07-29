# Nursery + old HTTP::Headers Hash regression (Phase 4 / process GC).
#
# OverflowError/SEGV in HTTP keep-alive Hash lookup when minor GC swept nursery
# String keys that lived only inside an old Hash.@entries blob.
#
# Standalone (not process_spec): Spec runner + process GC + nursery was flaky
# on CI (SEGV during Spec reporting after this example).
#
# Build: crystal build -Dgc_none bench/nursery_headers.cr -o bin/nursery_headers
# Run:   ./bin/nursery_headers

{% unless flag?(:gc_none) %}
  raise "nursery_headers requires -Dgc_none (gcry as process GC)"
{% end %}

require "http"
require "../src/gcry"

h = Gcry.default_heap
old_soft = h.soft_dirty_max_pct
old_nursery = h.nursery_enabled

begin
  h.nursery_enabled = true
  h.soft_dirty_max_pct = 0 # force scan_object_for_nursery fallback
  Gcry.register_hash(HTTP::Headers::Key, String | Array(String))

  headers = HTTP::Headers.new
  headers["Connection"] = "keep-alive"
  # Promote Hash + entries out of nursery.
  GC.collect
  headers["X-Nursery"] = "young-#{Random.rand(1_000_000)}"
  young = headers["X-Nursery"]
  h.minor_collect(scan_stack: true)
  GC.collect

  raise "Connection lost" unless headers["Connection"] == "keep-alive"
  raise "X-Nursery lost" unless headers["X-Nursery"] == young
  raise "keep_alive? false" unless HTTP.keep_alive?(HTTP::Request.new("GET", "/", headers))
ensure
  h.soft_dirty_max_pct = old_soft
  h.nursery_enabled = old_nursery
end

puts "nursery_headers ok"
