require "../wt/src/gcry"
# Header layout, TLAB off, alloc batch off, lazy sweep, four churning threads:
# how many collections did a frozen freelist class move into the stop?
heap = Gcry.default_heap
stop = Atomic(Int32).new(0)
workers = Array(Thread).new(4) do |w|
  Thread.new do
    keep = Array(Void*).new(256, Pointer(Void).null)
    i = 0
    until stop.get == 1
      sz = 16 + ((i &* 7919 &+ w) % 48) * 16
      p = GC.malloc(sz)
      old = keep[i % 256]
      GC.free(old) unless old.null? || (i % 3) != 0
      keep[i % 256] = p
      i &+= 1
    end
  end
end
t0 = Time.instant
collects = 0
while Time.instant - t0 < 20.seconds
  GC.collect
  collects += 1
  sleep 5.milliseconds
end
stop.set(1)
workers.each(&.join)
puts "alloc_batch=#{heap.alloc_batch} bitmap_alloc=#{heap.bitmap_alloc?} lazy=#{heap.lazy_sweep} collects=#{collects} " \
     "stop_frozen_sweeps_in_stop=#{heap.stop_frozen_sweeps_in_stop} stop_sweep_freelist_declined=#{heap.stop_sweep_freelist_declined}"
