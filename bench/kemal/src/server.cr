# Realistic Kemal app for process-GC load testing.
#
# Setup:  cd bench/kemal && shards install
# gcry:   crystal build -Dgc_none --release src/server.cr -o ../../bin/kemal-gcry
# boehm:  crystal build --release src/server.cr -o ../../bin/kemal-boehm
# Run:    PORT=3001 ../../bin/kemal-gcry
# Load:   wrk -c 100 -d 30 http://127.0.0.1:3001/
#         wrk -c 100 -d 30 http://127.0.0.1:3001/json
#
# Parallel EC (Crystal ≥ 1.21): default starts at capacity 1. Resize via
#   EC_PARALLELISM=4 PORT=3001 ../../bin/kemal-gcry
# (calls Fiber::ExecutionContext.default.resize — not CRYSTAL_WORKERS).
# Pair with GCRY_TLAB=1 on gcry when measuring Parallel+TLAB.
#
# Or from repo root: make bench-kemal-wrk
# A/B Boehm:         make bench-kemal-boehm && PORT=3001 ./bin/kemal-boehm

{% if flag?(:gc_none) %}
  require "gcry"
  require "../../performance/header_policy"
  HeaderPolicyExperiment.apply(Gcry.default_heap)
{% end %}

require "kemal"
require "json"

{% if flag?(:gc_none) %}
  # Precise Hash layout for HTTP::Headers — without it, @indices/@entries blobs
  # are only word-scanned via the Hash shell; under Parallel EC that still UAFs
  # in Headers#[]? / keep_alive? (GDB: Pointer#[] on garbage @indices ≈ ASCII).
  # See bench/nursery_headers.cr.
  Gcry.register_hash(HTTP::Headers::Key, String | Array(String))
{% end %}

logging false

# Default Parallel EC capacity is 1; raise max parallelism before Kemal binds.
if (n = ENV["EC_PARALLELISM"]?.try(&.to_i?)) && n >= 1
  Fiber::ExecutionContext.default.resize(n)
end

# `EXTRA_THREADS=N` parks N plain threads on a pipe read for the life of the
# process. It reproduces the shape of an EC1 app with one extra thread of its
# own (a driver, a logger), which is all it takes to cross gcry's
# multi-mutator boundary (> 2 threads besides the idle collector): the fat
# app's cuts sat on it, at 2 or 3 threads from one rebuild to the next
# (`bench/log/linux/2026-08-09-105503-root-phase/`). The read is retried on
# EINTR, which the collector's suspend signal causes; a thread that exited
# would drop the process back under the boundary unnoticed.
if (extra = ENV["EXTRA_THREADS"]?.try(&.to_i?)) && extra > 0
  parked_fds = uninitialized Int32[2]
  raise "pipe() failed" unless LibC.pipe(parked_fds) == 0
  read_fd = parked_fds[0]
  extra.times do |i|
    Thread.new(name: "extra-#{i}") do
      byte = uninitialized UInt8[1]
      loop do
        break if LibC.read(read_fd, byte.to_unsafe, 1) >= 0
        break unless Errno.value == Errno::EINTR
      end
    end
  end
end

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
    Gcry::Observability.json_stats
  end

  get "/metrics" do |env|
    env.response.content_type = "text/plain; version=0.0.4"
    Gcry.prometheus_text
  end

  # What `/gc-stats` cannot carry (its field list is full): platform counters a
  # root-phase cut needs to tell a slow probe from a refused one. Darwin's page
  # query falls back to scanning a whole range when the kernel refuses it, and
  # the only trace of that is this count.
  get "/gc-extra" do |env|
    env.response.content_type = "application/json"
    {
      page_query_errors: {% if flag?(:darwin) %}Gcry::Platform.page_query_errors{% else %}0_u64{% end %},
      host_page_size:    Gcry::Platform.host_page_size,
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

{% if flag?(:gc_none) %}
  # Research: what the parked-fiber lag costs on this app, in bytes and in the
  # phase timer it lands in. Sampled: `last_roots_fibers_ns` is per collection,
  # so a poller keyed on the collection counter sees nearly every one.
  if ENV["GCRY_LAG_DUMP"]? == "1"
    h = Gcry.default_heap.not_nil!
    seen = 0_u64
    froots = 0_u64
    pause = 0_u64
    samples = 0_u64
    spawn do
      loop do
        c = h.collections
        if c != seen
          seen = c
          froots += h.last_roots_fibers_ns
          pause += h.last_pause_ns
          samples += 1
        end
        sleep 100.microseconds
      end
    end
    at_exit do
      read = h.fiber_lag_sp_known_bytes + h.fiber_lag_sp_unknown_bytes
      m = Gcry.metrics
      STDERR.puts "LAGDUMP collections=#{h.collections} scans=#{h.fiber_lag_scans} " \
                  "nominal=#{h.fiber_lag_window_bytes} read=#{read} " \
                  "samples=#{samples} froots_ns=#{froots} sampled_pause_ns=#{pause} " \
                  "pause_p50_ns=#{m.pause_p50_ns} pause_p99_ns=#{m.pause_p99_ns}"
    end
  end
{% end %}

Kemal.config.port = (ENV["PORT"]? || "3001").to_i
Kemal.run
