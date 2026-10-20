puts "Fiber@context=#{offsetof(Fiber, @context)} Fiber@next=#{offsetof(Fiber, @next)} Fiber@previous=#{offsetof(Fiber, @previous)} instance_sizeof(Fiber)=#{instance_sizeof(Fiber)}"
puts "Context@resumable=#{offsetof(Fiber::Context, @resumable)}"
s = "  claim_probe: free_after_minor=true free_after_major=true minors=12 tlab_hits=32 tlab_refills=10"
puts "String header=#{String::HEADER_SIZE} 'ab_refil' index=#{s.index("ab_refil")} object offset=#{String::HEADER_SIZE + s.index!("ab_refil")}"
v = 0x6c696665725f6271_u64 - 0x10
bytes = Bytes.new(8) { |i| ((v >> (8*i)) & 0xff).to_u8 }
puts "fault-0x10 little-endian bytes: #{String.new(bytes).inspect}"
