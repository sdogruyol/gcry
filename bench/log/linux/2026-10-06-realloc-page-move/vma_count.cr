{% if flag?(:gc_none) %}
  require "gcry"
{% end %}

# Grow ARGV[0] arrays to ARGV[1] elements each and count the process's mappings.
def maps : Int32
  File.read("/proc/self/maps").count('\n')
end

n = ARGV[0].to_i
size = ARGV[1].to_i
before = maps
keep = Array(Array(Int64)).new
n.times do
  a = [] of Int64
  size.times { |i| a << i.to_i64 }
  keep << a
end
GC.collect
after = maps
ok = keep.all? { |a| a.each_with_index.all? { |v, i| v == i } }
puts "arrays=#{n} elems=#{size} maps before=#{before} after=#{after} per-array=#{((after - before) / n).round(2)} ok=#{ok} moves=#{Gcry.default_heap.realloc_moves}"
