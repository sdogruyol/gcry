# Crystal GC API + compiler type_id contract under `-Dgc_none` + gcry (Phase 6.3).
#
# Mirrors Crystal stdlib `spec/std/gc_spec.cr` and extends with malloc/collect
# and `@crystal_type_id` header checks.
#
# Build: crystal build -Dgc_none bench/compiler_gc_contract.cr -o bin/compiler_gc_contract
# Run:   ./bin/compiler_gc_contract

{% unless flag?(:gc_none) %}
  raise "compiler_gc_contract requires -Dgc_none (gcry as process GC)"
{% end %}

require "../src/gcry"

module Contract
  class_property passed = 0
  class_property failed = 0

  def self.check(label : String, & : ->) : Nil
    begin
      yield
      puts "  ok  # #{label}"
      self.passed += 1
    rescue ex
      puts "  FAIL # #{label}: #{ex.message}"
      self.failed += 1
    end
  end
end

class ContractTypeA
  property n : Int32 = 7
end

class ContractTypeB
  property s : String = "x"
end

puts "compiler_gc_contract (Crystal #{Crystal::VERSION})"

# --- Crystal stdlib gc_spec.cr subset ---
Contract.check("typeof(GC.stats) == GC::Stats") do
  raise "bad typeof" unless typeof(GC.stats) == GC::Stats
end

Contract.check("GC.enable raises when not disabled") do
  begin
    GC.enable
    raise "expected Exception"
  rescue ex : Exception
    raise "wrong message: #{ex.message}" unless ex.message == "GC is not disabled"
  end
end

Contract.check("GC.stats is GC::Stats") do
  raise "not Stats" unless GC.stats.is_a?(GC::Stats)
end

Contract.check("GC.prof_stats is GC::ProfStats") do
  raise "not ProfStats" unless GC.prof_stats.is_a?(GC::ProfStats)
end

# --- malloc / free / collect contract ---
Contract.check("GC.malloc clears and is_heap_ptr") do
  p = GC.malloc(64)
  raise "not heap" unless GC.is_heap_ptr(p)
  64.times { |i| raise "nonzero at #{i}" unless p.as(UInt8*)[i] == 0 }
  GC.free(p)
end

Contract.check("GC.malloc_atomic is_heap_ptr") do
  p = GC.malloc_atomic(32)
  raise "not heap" unless GC.is_heap_ptr(p)
  GC.free(p)
end

Contract.check("GC.realloc preserves prefix") do
  p = GC.malloc(16)
  16.times { |i| p.as(UInt8*)[i] = i.to_u8 }
  q = GC.realloc(p, 128)
  16.times { |i| raise "mismatch #{i}" unless q.as(UInt8*)[i] == i.to_u8 }
  GC.free(q)
end

Contract.check("GC.collect keeps live Crystal objects") do
  keep = Array(Int32).new(50) { |i| i }
  GC.collect
  raise "lost" unless keep.size == 50 && keep[49] == 49
end

Contract.check("GC.disable / enable round-trip") do
  GC.disable
  begin
    GC.enable
  ensure
    begin
      GC.enable
    rescue
    end
  end
  begin
    GC.enable
    raise "still disabled?"
  rescue ex : Exception
    raise "wrong: #{ex.message}" unless ex.message == "GC is not disabled"
  end
end

# --- @crystal_type_id header matches compiler ---
Contract.check("instance header type_id matches crystal_instance_type_id") do
  a = ContractTypeA.new
  b = ContractTypeB.new
  tid_a = Pointer(Int32).new(a.as(Void*).address).value
  tid_b = Pointer(Int32).new(b.as(Void*).address).value
  raise "A mismatch #{tid_a} vs #{ContractTypeA.crystal_instance_type_id}" unless tid_a == ContractTypeA.crystal_instance_type_id
  raise "B mismatch #{tid_b} vs #{ContractTypeB.crystal_instance_type_id}" unless tid_b == ContractTypeB.crystal_instance_type_id
  raise "A/B type_ids collided" if tid_a == tid_b
end

Contract.check("Array type_id is registered for layout") do
  tid = Array(String).crystal_instance_type_id
  raise "no layout" if Gcry::Layout.entry_for(tid).nil?
end

Contract.check("GC.stats heap_size stays positive after malloc") do
  keep = Array(UInt8).new(64) { 1_u8 }
  GC.collect
  after = GC.stats.heap_size
  raise "heap_size not positive (#{after})" unless after > 0
  keep.size
end

puts
if Contract.failed > 0
  puts "#{Contract.failed} failed, #{Contract.passed} passed"
  exit 1
end
puts "all #{Contract.passed} checks passed"
