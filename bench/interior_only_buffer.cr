# A live buffer LLVM holds only by an interior pointer.
#
# `live[i % LIVE]` inside a hot loop is strength-reduced under `--release`:
# the register holds `buffer + (i % LIVE) * 8`, the base `live.@buffer` is
# dead, and the `Array` object itself is only reached through a spill slot
# the optimiser is free to drop once nothing reads `live` again. Base-only
# ambient marking then sees no pointer *at* the buffer and frees it under
# the loop; the next write is into a released chunk (SIGSEGV, or with
# `GCRY_SEGV_REPORT=1`: "in a chunk gcry RELEASED ... large-object release,
# at collection 1"). bdwgc as Crystal links it has always resolved
# interiors, so this shape has run safely under every Crystal release.
#
# Found 2026-09-06 on v0.22.0 (3 of 3 runs, debug build clean); fixed by
# making `allow_interior_pointers` the process default. This program is the
# gate: the default arm must finish and see its objects intact, the
# `GCRY_DISABLE_INTERIOR=1` arm must fault — a control that cannot go red
# proves nothing.
#
# Build: crystal build -Dgc_none --release bench/interior_only_buffer.cr
# Run:   make interior-only-buffer
{% unless flag?(:gc_none) %}
  raise "interior_only_buffer requires -Dgc_none (gcry as process GC)"
{% end %}
{% unless flag?(:release) %}
  raise "interior_only_buffer requires --release: the debug build keeps the base live"
{% end %}

require "../src/gcry"

class Node
  property a : Node?
  property b : Int64 = 0
end

LIVE  = (ARGV[0]? || "400000").to_i
CHURN = (ARGV[1]? || "2000000").to_i

live = Array(Node).new(LIVE) { |k| n = Node.new; n.b = k.to_i64; n }
h = Gcry.default_heap
m0 = h.major_collections

i = 0
sink = nil
while i < CHURN
  n = Node.new
  n.a = live[i % LIVE] if (i & 7) == 0
  sink = n
  i += 1
end

bad = 0
live.each_with_index { |n, k| bad += 1 unless n.b == k }
majors = h.major_collections - m0
puts "interior_only_buffer: live=#{LIVE} churn=#{CHURN} majors=#{majors} corrupted=#{bad} interior=#{h.allow_interior_pointers} #{sink.class}"
abort "FAIL: #{bad} of #{LIVE} live objects lost their payload" unless bad == 0
abort "FAIL: no collection ran - the loop never put the buffer at risk" if majors == 0
