# A live byte buffer LLVM holds only by a misaligned interior pointer.
#
# The companion of `interior_only_buffer.cr`. A byte-wise loop over a
# `Bytes` buffer is strength-reduced under `--release` to a raw pointer
# induction variable, and after the first byte that pointer is word-aligned
# only one time in eight. With the base dead, the collector's cheap
# alignment filter (`scan_unaligned_candidates = false`) rejects the one
# reference the loop has before `find_block` ever runs, and the buffer is
# freed under it. bdwgc resolves the same word through `GC_base`, so every
# Crystal release ran this shape safely.
#
# Gate: the default arm must finish with its checksum intact; the
# `GCRY_ALIGNED_CANDIDATES=1` arm must fault or corrupt.
#
# Build: crystal build -Dgc_none --release bench/unaligned_only_buffer.cr
# Run:   make unaligned-only-buffer
{% unless flag?(:gc_none) %}
  raise "unaligned_only_buffer requires -Dgc_none (gcry as process GC)"
{% end %}
{% unless flag?(:release) %}
  raise "unaligned_only_buffer requires --release: the debug build keeps the base live"
{% end %}

require "../src/gcry"

BYTES  = (ARGV[0]? || "1048576").to_i
ROUNDS = (ARGV[1]? || "64").to_i

# The buffer is made in a callee that hands back only a pointer one byte
# *into* it: the base never lives in this frame, and the callee's frame is
# overwritten by the calls below. A large object, so a lost root releases
# the whole chunk and the next read is a fault rather than a reused block.
@[NoInline]
def make_buffer(bytes : Int32) : UInt8*
  buf = Bytes.new(bytes) { |i| (i &* 31 &+ 7).to_u8! }
  buf.to_unsafe + 1
end

expected = 0_u64
(1...BYTES).each { |i| expected &+= (i &* 31 &+ 7).to_u8! }

h = Gcry.default_heap
m0 = h.major_collections

# Only the induction pointer exists here, and it is word-aligned one byte
# in eight; the allocation in the loop body brings the collector in.
q = make_buffer(BYTES)
sum = 0_u64
sink = nil
ROUNDS.times do |r|
  n = BYTES - 1
  while n > 0
    sum &+= q.value
    sink = Bytes.new(4096) if (q.address & 0xff) == 1
    q += 1
    n -= 1
  end
  q -= BYTES - 1
end

majors = h.major_collections - m0
ok = sum == expected &* ROUNDS
puts "unaligned_only_buffer: bytes=#{BYTES} rounds=#{ROUNDS} majors=#{majors} checksum=#{ok ? "ok" : "CORRUPT"} unaligned=#{h.scan_unaligned_candidates} #{sink.class}"
abort "FAIL: checksum mismatch - the buffer was reclaimed and reused under the loop" unless ok
abort "FAIL: no collection ran - the loop never put the buffer at risk" if majors == 0
