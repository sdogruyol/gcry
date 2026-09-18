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

# And on Linux, that the clamp *clamped*. The assertion above passes in a state
# where it did nothing: with `GCRY_DISABLE_SP_CLAMP=1` this sample read
# `hits=0 fallbacks=2` and called it ok, because a fallback counts a scan that
# had no SP to clamp with. `hits > 0` is the difference, and it is Linux-only
# on purpose — Darwin's Mach stop reports `hits=0 fallbacks=0` by design, which
# is why the weaker assertion above exists at all.
#
# This is also what makes the knob a red arm instead of an orphan: it was read
# by `src/` and exercised by nothing, and it used to hang every harness it was
# set on (`bench/log/linux/2026-09-18-sp-clamp-knob/FINDINGS.md`).
{% if flag?(:linux) %}
  if hits == 0
    abort "the SP clamp recorded no hits: other-thread scans are running the full " \
          "pthread range, which is what GCRY_DISABLE_SP_CLAMP=1 asks for and not " \
          "what this build should do"
  end
{% end %}
puts "ok"
