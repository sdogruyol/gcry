require "gcry"
require "json"

# Churn enough to force several major collections under the process GC,
# so the conservative scan actually resolves many candidate words.
acc = [] of String
200_000.times do |i|
  acc << "x" * (16 + (i % 64))
  acc.shift if acc.size > 4000
end
GC.collect
h = Gcry.default_heap
puts({
  radix_env:      Gcry::Heap.chunk_radix_from_env,
  bitmap_env:     Gcry::Heap.bitmap_marks_from_env,
  fast_hits:      h.radix_fast_hits,
  slow_lookups:   h.radix_slow_lookups,
  oversize_skips: h.radix_oversize_skips,
  collections:    h.collections,
  phase_mark_ns:  h.last_phase_mark_ns,
}.to_json)
