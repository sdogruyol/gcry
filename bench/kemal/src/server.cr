# Realistic Kemal app for process-GC load testing.
#
# Setup:  cd bench/kemal && shards install
# gcry:   crystal build -Dgc_none --release src/server.cr -o ../../bin/kemal-gcry
# boehm:  crystal build --release src/server.cr -o ../../bin/kemal-boehm
# Run:    ../../bin/kemal-gcry
# Load:   wrk -c 100 -d 30 http://localhost:3001/
#
# Or from repo root: make bench-kemal-wrk
# A/B Boehm:         make bench-kemal-boehm && PORT=3001 ./bin/kemal-boehm

{% if flag?(:gc_none) %}
  require "gcry"
{% end %}

require "kemal"

logging false

get "/" do
  "Hello World"
end

# Light alloc pressure — closer to a real handler than a static string alone.
get "/json" do |env|
  env.response.content_type = "application/json"
  {message: "hello", n: Random.rand(1_000_000)}.to_json
end

Kemal.config.port = (ENV["PORT"]? || "3001").to_i
Kemal.run
