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
