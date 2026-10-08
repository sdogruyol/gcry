# Diagnostic for process_spec/regression/35 on Windows: after 300 threads are
# joined, how many birth roots are still outstanding after each collection, and
# do they drain later? Prints one line per collection.
#   crystal build -Dgc_none bench/log/windows/2026-10-06-vm-validation/spec35-probe.cr -o bin/spec35-probe
require "../../../../src/gcry"

alias TBR = Gcry::ThreadBirthRoot

def snap(tag)
  heap = Gcry.default_heap
  puts "#{tag}: collections=#{heap.collections} outstanding=#{TBR.outstanding} armed=#{TBR.armed} " \
       "released=#{TBR.released} released_dead=#{TBR.released_dead} overflows=#{TBR.overflows} capacity=#{TBR.capacity} " \
       "threads_listed=#{count_listed}"
end

def count_listed
  n = 0
  Thread.unsafe_each { n += 1 }
  n
end

threads = (ARGV[0]? || "300").to_i
GC.collect
baseline = TBR.outstanding
snap("baseline")
ready = Atomic(Int32).new(0)
go = Atomic(Int32).new(0)
workers = [] of Thread
threads.times do
  workers << Thread.new do
    ready.add(1)
    until go.get != 0
      Thread.yield
    end
  end
end
until ready.get == threads
  Thread.yield
end
snap("all alive")
go.set(1)
# Crystal 1.21: a thread that finished its block marks itself detached in
# Thread#start's ensure, and Thread#join then skips WaitForSingleObject.
# Checked right before each join: such a join returns without waiting.
self_detached = 0
workers.each do |t|
  self_detached += 1 if t.@detached.get
  t.join
end
puts "self-detached before join (join skips WaitForSingleObject): >= #{self_detached} of #{threads}"
snap("joined")
t0 = Time.instant
20.times do |i|
  GC.collect
  snap("collect #{i + 1} +#{(Time.instant - t0).total_milliseconds.round(1)}ms")
  break if TBR.outstanding <= baseline && i >= 2
end
puts(TBR.outstanding <= baseline ? "DRAINED" : "STUCK outstanding=#{TBR.outstanding} baseline=#{baseline}")
