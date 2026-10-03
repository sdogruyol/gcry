{% if flag?(:gc_none) %}
  require "../../../../src/gcry"
{% end %}

class AllocNode
  property left : AllocNode?
  property right : AllocNode?

  def initialize(@left, @right)
  end
end

class TlsProbe
  @[ThreadLocal]
  @@x : UInt128 = 0_u128

  @[NoInline]
  def self.bump : Nil
    @@x &+= 1
  end

  def self.value : UInt128
    @@x
  end
end

n = (ARGV[0]? || "50000000").to_i
arm = {{ flag?(:gc_none) ? "gcry" : "boehm" }}

t0 = Time.instant
sink = 0_u64
n.times do
  p = GC.malloc(48)
  sink &+= p.address & 1
end
puts "#{arm} GC.malloc(48): #{((Time.instant - t0).total_nanoseconds / n).round(2)} ns"

t0 = Time.instant
n.times do
  node = AllocNode.new(nil, nil)
  sink &+= node.object_id & 1
end
puts "#{arm} AllocNode.new: #{((Time.instant - t0).total_nanoseconds / n).round(2)} ns"

t0 = Time.instant
(n * 4).times { TlsProbe.bump }
puts "#{arm} tls read+write: #{((Time.instant - t0).total_nanoseconds / (n * 4)).round(2)} ns (#{TlsProbe.value}) sink=#{sink}"
