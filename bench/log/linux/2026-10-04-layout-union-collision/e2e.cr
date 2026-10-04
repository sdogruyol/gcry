require "json"
require "../../../../../src/gcry"

N = 20_000
holders = Array(Array(JSON::Any)).new(N)
N.times do |i|
  inner = [JSON::Any.new("v#{i}")]
  holders << [JSON::Any.new(inner), JSON::Any.new("s#{i}")]
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
    h[0].as_a[0].as_s == "v#{i}" && h[1].as_s == "s#{i}"
  rescue
    false
  end
  bad += 1 unless ok
end
puts "bad=#{bad} of #{N}"
