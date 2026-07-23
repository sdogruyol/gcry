# Process-GC Hash/JSON mutation stress (dogfood beyond Kemal /).
# Build: crystal build -Dgc_none samples/json_churn.cr -o bin/json_churn
# Run:   ./bin/json_churn [rounds]

require "../src/gcry"
require "json"

rounds = (ARGV[0]? || "2000").to_i
alive = [] of JSON::Any

rounds.times do |i|
  raw = JSON.build do |json|
    json.object do
      json.field "id", i
      json.field "name", "user-#{i % 97}"
      json.field "blob", "x" * (16 + i % 48)
      json.field "items" do
        json.array do
          4.times do |j|
            json.object do
              json.field "j", j
              json.field "v", "item-#{j}-#{i % 13}"
            end
          end
        end
      end
    end
  end

  obj = JSON.parse(raw)
  alive << obj
  alive.shift if alive.size > 64

  # Mutate retained objects (pointer stores into already-live heap).
  if (cur = alive[i % alive.size]?) && cur.as_h?
    cur.as_h["tick"] = JSON::Any.new(i.to_i64)
  end

  GC.collect if i % 200 == 199
end

GC.collect
stats = GC.stats
prof = GC.prof_stats
pause = Gcry.pause_stats
puts "rounds=#{rounds} kept=#{alive.size} heap=#{stats.heap_size} unmapped=#{stats.unmapped_bytes}"
puts "prof gc_no=#{prof.gc_no} reclaimed=#{prof.bytes_reclaimed_since_gc} before=#{prof.bytes_before_gc}"
puts "pause p50_us=#{pause.p50_ns // 1000} p99_us=#{pause.p99_ns // 1000} max_us=#{pause.max_ns // 1000} count=#{pause.count}"
