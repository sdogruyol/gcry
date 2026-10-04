require "json"
require "http/server"
require "../../../../../src/gcry"

# Keep the program's type ids those of an HTTP + JSON app.
HTTP::Server.new { |ctx| ctx.response.print "x" } if ARGV.includes?("--never")

N = 20_000
mode = ARGV[0]? || "literal"
holders = Array(JSON::Any).new(N)
N.times do |i|
  inner = JSON::Any.new({"k#{i}" => JSON::Any.new("v#{i}")})
  if mode == "parse"
    holders << JSON.parse(%([{"k#{i}": "v#{i}"}, null, #{i}]))
  else
    holders << JSON::Any.new([inner, JSON::Any.new(nil), JSON::Any.new(i.to_i64), JSON::Any.new(nil)])
  end
end
3.times do
  GC.collect
  junk = Array(String).new
  200_000.times { |j| junk << "garbage-#{j}-xxxxxxxxxxxxxxxx" }
  junk.clear
end
GC.collect
bad = 0
holders.each_with_index do |h, i|
  ok = begin
    h[0]["k#{i}"].as_s == "v#{i}"
  rescue
    false
  end
  bad += 1 unless ok
end
puts "#{mode}: bad=#{bad} of #{N}"
