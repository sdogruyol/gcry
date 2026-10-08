# Allocation-heavy interpreted program: interpreter-allocated objects (host
# `GC.malloc`) and `GC_*` calls from the interpreted `GC` module, with
# collections running underneath the interpreter.
class Node
  getter value : Int32
  property next_node : Node?

  def initialize(@value : Int32, @next_node : Node? = nil)
  end
end

checksum = 0_i64
50.times do |round|
  head = nil
  2_000.times { |i| head = Node.new(i, head) }
  strings = Array.new(500) { |i| "s#{round}-#{i}" * 4 }
  table = Hash(String, Int32).new
  strings.each_with_index { |s, i| table[s] = i }
  n = head
  while n
    checksum &+= n.value
    n = n.next_node
  end
  checksum &+= table.size
  GC.collect if round % 10 == 0
end
stats = GC.stats
puts "checksum=#{checksum} heap_size>0=#{stats.heap_size > 0} total_bytes>0=#{stats.total_bytes > 0}"
expected = 50_i64 * (1999_i64 * 2000 // 2 + 500)
raise "checksum #{checksum} != #{expected}" unless checksum == expected
