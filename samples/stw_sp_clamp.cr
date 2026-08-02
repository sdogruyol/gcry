# Process-GC smoke: STW should capture another thread's SP and clamp the scan.
{% if flag?(:gc_none) %}
  require "../src/gcry"
{% else %}
  abort "build with -Dgc_none"
{% end %}

# Park a real OS thread during collect so STW always has something to
# suspend+scan. Channel+spawn alone only wakes Monitor briefly and races
# (Darwin CI: installed=true hits=0 fallbacks=0).
# Raw Thread.new has no Fiber execution_context — spin on Atomic (no Channel/sleep).
ready = Atomic(Int32).new(0)
release = Atomic(Int32).new(0)

worker = Thread.new do
  ready.set(1)
  while release.get == 0
  end
end

until ready.get == 1
end

GC.collect
h = Gcry.default_heap
hits = h.sp_clamp_hits
fallbacks = h.sp_clamp_fallbacks
installed = Gcry::Platform.stw_sp_capture_installed?

release.set(1)
worker.join

puts "installed=#{installed} hits=#{hits} fallbacks=#{fallbacks}"
abort "STW SP capture not installed" unless installed
abort "expected hits or fallbacks from other-thread scan" if hits == 0 && fallbacks == 0
puts "ok"
