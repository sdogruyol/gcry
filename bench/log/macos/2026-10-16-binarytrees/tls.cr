# What one thread-local read and one small allocation cost, per platform:
# Crystal's `@[ThreadLocal]` (a `NoInline` accessor; on Mach-O it calls the
# variable's TLV thunk, `tlv_get_addr`), `pthread_getspecific`, and the
# allocation paths of the binary's collector. Median of 7 trials of N ops.
{% if flag?(:gc_none) %}
  require "gcry"
{% end %}

lib LibC
  {% if flag?(:darwin) %}
    alias ProbeKeyT = ULong
  {% else %}
    alias ProbeKeyT = UInt
  {% end %}
  fun pthread_key_create(key : ProbeKeyT*, destructor : Void* -> Void) : Int
  fun pthread_setspecific(key : ProbeKeyT, value : Void*) : Int
  fun pthread_getspecific(key : ProbeKeyT) : Void*
end

class Probe
  @[ThreadLocal]
  @@cache : UInt128 = 0_u128
  @@plain : UInt128 = 0_u128

  def self.cache_read : UInt128
    @@cache
  end

  def self.cache_write(v : UInt128) : Nil
    @@cache = v
  end

  @[NoInline]
  def self.plain_read : UInt128
    @@plain
  end

  def self.plain_write(v : UInt128) : Nil
    @@plain = v
  end
end

class Node
  property left : Node?
  property right : Node?
  property item : Int32

  def initialize(@item)
  end
end

N = (ARGV[0]? || "50000000").to_i
ARM = {{ flag?(:gc_none) ? "gcry" : "boehm" }}

def trial(label, &block : -> UInt64)
  times = Array(Float64).new
  sink = 0_u64
  7.times do
    t0 = Time.instant
    sink &+= block.call
    times << (Time.instant - t0).total_nanoseconds / N
  end
  times.sort!
  puts "TLS #{ARM} #{label}: #{times[3].round(3)} ns [#{times[1].round(3)}, #{times[5].round(3)}] (#{sink & 1})"
end

key = uninitialized LibC::ProbeKeyT
LibC.pthread_key_create(pointerof(key), ->(p : Void*) {})
LibC.pthread_setspecific(key, Pointer(Void).new(0x1234_u64))
Probe.cache_write(0x1234_u128)
Probe.plain_write(0x1234_u128)

trial("empty loop") do
  s = 0_u64
  N.times { |i| s &+= i.to_u64 }
  s
end
trial("noinline plain read") do
  s = 0_u64
  N.times { s &+= Probe.plain_read.to_u64! }
  s
end
trial("ThreadLocal UInt128 read") do
  s = 0_u64
  N.times { s &+= Probe.cache_read.to_u64! }
  s
end
trial("pthread_getspecific") do
  s = 0_u64
  N.times { s &+= LibC.pthread_getspecific(key).address }
  s
end
trial("GC.malloc(24)") do
  s = 0_u64
  N.times { s &+= GC.malloc(24).address & 1 }
  s
end
trial("Node.new") do
  s = 0_u64
  N.times { |i| s &+= Node.new(i).object_id & 1 }
  s
end
