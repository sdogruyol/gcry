# Process-GC smoke: STW should capture Monitor RSP and clamp other-thread scan.
{% if flag?(:gc_none) %}
  require "../src/gcry"
{% else %}
  abort "build with -Dgc_none"
{% end %}

# Wake the ExecutionContext Monitor so STW has another OS thread to suspend.
ch = Channel(Nil).new
spawn { ch.send(nil) }
ch.receive

GC.collect
h = Gcry.default_heap
hits = h.sp_clamp_hits
fallbacks = h.sp_clamp_fallbacks
installed = Gcry::Platform.stw_sp_capture_installed?

puts "installed=#{installed} hits=#{hits} fallbacks=#{fallbacks}"
abort "STW SP capture not installed" unless installed
abort "expected hits or fallbacks from other-thread scan" if hits == 0 && fallbacks == 0
puts "ok"
