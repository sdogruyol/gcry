# Mark micro-benchmark: a fixed graph held live, `GC.collect` N times.
# main_mark <jsonparse|jsongen|small> [N] [evict_mib]
# `evict_mib` > 0 writes that many MiB of an atomic buffer before each
# collection, so the collector's code and data start cold, as in a program
# that streams between collections (Revcomp, RegexDna).
{% if flag?(:gc_none) %}
  require "gcry"
{% end %}
require "./metric"

kind = ARGV[0]
n = (ARGV[1]? || "10").to_i
evict = (ARGV[2]? || "0").to_i
held = case kind
       when "jsonparse"
         j = JsonGenerate.new(300_000)
         j.run
         JSON.parse(j.@result.to_s)
       when "jsongen"
         JsonGenerate.new(600_000)
       else
         Array.new(100) { |i| {i.to_s, [i, i + 1], {"k#{i}" => i}} }
       end
buf = evict > 0 ? Bytes.new(evict * 1024 * 1024) : Bytes.empty
GC.collect
sum = 0_u64
n.times do |k|
  buf.fill((k & 255).to_u8) if evict > 0
  GC.collect
end
puts "#{kind} done #{held.hash & 1} #{buf.size}"
