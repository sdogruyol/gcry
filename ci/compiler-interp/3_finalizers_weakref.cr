# Finalizers and WeakRef from interpreted code: `GC.add_finalizer` is
# `GC_register_finalizer_ignore_self` with an interpreter closure as the
# callback, which gcry calls after a collection; `WeakRef` is `GC_base` +
# `GC_general_register_disappearing_link`.
require "weak_ref"

class Tracked
  class_property finalized = 0

  def initialize(@payload : Array(Int32))
  end

  def finalize
    Tracked.finalized += 1
  end
end

def make_garbage(n)
  n.times { Tracked.new(Array.new(16) { |i| i }) }
end

def make_weak(n)
  Array.new(n) { WeakRef.new(Tracked.new([1, 2, 3])) }
end

make_garbage(20_000)
weaks = make_weak(1_000)
10.times { GC.collect }
cleared = weaks.count { |w| w.value.nil? }
puts "finalized=#{Tracked.finalized} weak_cleared=#{cleared}/#{weaks.size}"
raise "no finalizer ran" if Tracked.finalized == 0
raise "no WeakRef was cleared" if cleared == 0
