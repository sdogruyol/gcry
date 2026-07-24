# Realistic Kemal app for process-GC load testing.
#
# Setup:  cd bench/kemal && shards install
# gcry:   crystal build -Dgc_none --release src/server.cr -o ../../bin/kemal-gcry
# boehm:  crystal build --release src/server.cr -o ../../bin/kemal-boehm
# Run:    PORT=3001 ../../bin/kemal-gcry
# Load:   wrk -c 100 -d 30 http://127.0.0.1:3001/
#         wrk -c 100 -d 30 http://127.0.0.1:3001/json
#
# Or from repo root: make bench-kemal-wrk
# A/B Boehm:         make bench-kemal-boehm && PORT=3001 ./bin/kemal-boehm

{% if flag?(:gc_none) %}
  require "gcry"
{% end %}

require "kemal"
require "json"

logging false

# Minimal handler — string literal, almost no alloc.
get "/" do
  "Hello World"
end

get "/gc-collect" do |env|
  env.response.content_type = "application/json"
  GC.collect
  {% if flag?(:gc_none) %}
    {ok: true, collections: Gcry.default_heap.collections}.to_json
  {% else %}
    {ok: true}.to_json
  {% end %}
end

# GC pause / heap snapshot for wrk A/B (gcry builds only).
{% if flag?(:gc_none) %}
  get "/gc-stats" do |env|
    env.response.content_type = "application/json"
    h = Gcry.default_heap
    p = Gcry.pause_stats
    s = GC.stats
    {
      collections:            h.collections,
      major_collections:      h.major_collections,
      heap_size:              s.heap_size,
      free_bytes:             s.free_bytes,
      bytes_since_gc:         s.bytes_since_gc,
      unmapped_bytes:         s.unmapped_bytes,
      pause_count:            p.count,
      pause_last_ns:          p.last_ns,
      pause_p50_ns:           p.p50_ns,
      pause_p99_ns:           p.p99_ns,
      pause_max_ns:           p.max_ns,
      pause_total_ns:         p.total_ns,
      phase_clear_ns:         h.last_phase_clear_ns,
      phase_roots_ns:         h.last_phase_roots_ns,
      phase_static_ns:        h.last_phase_static_ns,
      phase_stacks_ns:        h.last_phase_stacks_ns,
      phase_mark_ns:          h.last_phase_mark_ns,
      phase_sweep_ns:         h.last_phase_sweep_ns,
      large_free_bytes:       h.large_free_bytes,
      large_mapped_bytes:     h.large_mapped_bytes,
      small_mapped_bytes:     h.small_mapped_bytes,
      small_free_bytes:       h.small_free_bytes,
      large_cache_retain:     h.large_cache_retain,
      size_class_chunk_count: h.size_class_chunk_count,
      fully_free_chunk_bytes: h.fully_free_chunk_bytes,
      released_chunk_bytes:   h.released_chunk_bytes,
      size_class_live_bytes:  h.size_class_live_bytes,
      chunk_fill_lt25:        h.chunk_fill_lt25,
      chunk_fill_lt50:        h.chunk_fill_lt50,
      chunk_fill_lt75:        h.chunk_fill_lt75,
      chunk_fill_ge75:        h.chunk_fill_ge75,
      small_chunk_bytes:      h.small_chunk_bytes,
      soft_dirty_armed:       h.soft_dirty_armed?,
      soft_dirty_page_scans:  h.soft_dirty_page_scans,
      soft_dirty_fallbacks:   h.soft_dirty_fallbacks,
      soft_dirty_last_dirty:  h.last_soft_dirty_pages,
      soft_dirty_last_total:  h.last_soft_dirty_total,
      soft_dirty_max_pct:     h.soft_dirty_max_pct,
      dormant_chunk_bytes:    h.dormant_chunk_bytes,
      dontneed_bytes:         h.dontneed_bytes,
      empty_chunk_retain:     h.empty_chunk_retain,
      finalizer_entries:      h.finalizer_entry_count,
      weak_links:             h.finalizer_link_count,
    }.to_json
  end
{% end %}

# Alloc-heavy handler — closer to a real JSON API (nested objects, arrays, strings).
# Avoids Time formatting on the hot path (extra allocator churn / formatter state).
get "/json" do |env|
  env.response.content_type = "application/json"
  id = Random.rand(1_000_000)
  JSON.build do |json|
    json.object do
      json.field "ok", true
      json.field "id", id
      json.field "message", "hello"
      json.field "user" do
        json.object do
          json.field "name", "user-#{id % 1000}"
          json.field "active", true
          json.field "score", Random.rand(100)
        end
      end
      json.field "items" do
        json.array do
          8.times do |i|
            json.object do
              json.field "i", i
              json.field "label", "item-#{i}-#{id % 97}"
              json.field "blob", "x" * (24 + i * 3)
            end
          end
        end
      end
    end
  end
end

Kemal.config.port = (ENV["PORT"]? || "3001").to_i
Kemal.run
