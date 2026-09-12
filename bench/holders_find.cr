# Does the holders search find a pointer it is guaranteed to be able to find?
#
# Every investigation of a use-after-free on this heap has turned on one
# sentence — *"holders — none. Nothing in the root set, in a live block or on a
# fiber stack points into it"* — and a search that can miss makes every one of
# those conclusions weaker than it reads. On 2026-09-12 one report contradicted
# itself inside four lines: an execution context's `@schedulers` array was
# allocated, marked, and held its buffer's address at offset 16, and the same
# report's heap walk said **0 word(s) in 0 live block(s)** for that buffer.
#
# So this is the control the search never had. A holder is constructed whose
# only job is to hold the target's address in a known ivar at a known offset,
# in a live object the walk must visit, and the search is asked about it.
#
#   crystal build -Dgc_none bench/holders_find.cr -o bin/holders_find
#   bin/holders_find
#
# The gate is the count, not the text: the heap walk must report at least the
# one word that is certainly there.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "holders_find requires -Dgc_none (gcry as process GC)" %}
{% end %}

# Three shapes, because the walk resolves a block's payload and user address
# per block and the three classes reach that code differently: a small block
# in a size class, one big enough to be a different class, and a large-object
# chunk with its own header.
SMALL  =  16_u64
MEDIUM = 512_u64
LARGE  = 96_u64 * 1024

# The ivar is a `Pointer`, and that is not cosmetic. A holder whose only ivar
# is a `UInt64` has no inner pointers, so Crystal allocates it *atomic* and
# gcry never scans its payload — the address in it is not a root, the target is
# reclaimed, and the next `GC.malloc` hands the same block back. Measured while
# writing this: the control drew the small case's own address.
class Holder
  @slot : Pointer(UInt8)

  def initialize(@slot : Pointer(UInt8))
  end

  def slot : Pointer(UInt8)
    @slot
  end
end

heap = Gcry.default_heap.not_nil!

# Kept in a class variable so the holder objects are roots in their own right:
# the question is whether the walk finds the *word*, not whether the holder
# survives.
class Kept
  @@holders = [] of Holder

  def self.add(h : Holder) : Nil
    @@holders << h
  end

  def self.size : Int32
    @@holders.size
  end
end

# Addresses are stored masked everywhere except inside the holder's own ivar,
# so the only *heap* word carrying a target is the one under test. Storing them
# plainly in this array would put each address in the array's buffer — a live
# heap block — and every target, control included, would read as held.
KEY = 0x5A5A_A5A5_5A5A_A5A5_u64

record Case, name : String, masked : UInt64, size : UInt64

cases = [] of Case
[{"small", SMALL}, {"medium", MEDIUM}, {"large", LARGE}].each do |name, bytes|
  block = GC.malloc(bytes)
  Kept.add(Holder.new(block.as(UInt8*)))
  cases << Case.new(name, block.address ^ KEY, bytes)
end

# A collection first, so the search runs against a settled heap and the
# holders are marked rather than merely allocated.
GC.collect

puts "=== does the holders search find a word that is certainly there? ==="
puts "#{Kept.size} holder(s), each holding one target address in its @slot ivar"
puts ""

failures = 0
cases.each do |c|
  target = c.masked ^ KEY
  found = Gcry::PoisonHolders.heap_holders_count(heap, target, c.size)
  ok = found > 0
  failures += 1 unless ok
  puts "#{ok ? "ok  " : "FAIL"} #{c.name.ljust(7)} target 0x#{target.to_s(16)} #{c.size} bytes — heap holders found: #{found}"
end

puts ""
if failures > 0
  puts "FAIL #{failures} of #{cases.size} targets were held by a live, marked object in a"
  puts "known ivar and the search reported nothing. Every \"holders — none\" this"
  puts "search has ever printed is unreliable by that much."
  exit 1
end

# The other half: the search must not invent holders. An address no holder was
# built for, and whose only copy is masked, has to come back empty — or a
# non-zero count above says nothing.
control_masked = GC.malloc(SMALL).address ^ KEY
control_found = Gcry::PoisonHolders.heap_holders_count(heap, control_masked ^ KEY, SMALL)
puts "control  target 0x#{(control_masked ^ KEY).to_s(16)} held by nothing — heap holders found: #{control_found}"
if control_found > 0
  puts ""
  puts "INCONCLUSIVE — a block no holder points at reports #{control_found} holder(s), so the"
  puts "counts above are not attributable to the holders that were built."
  exit 2
end

puts ""
puts "ok — every constructed holder was found, and a block with none reports none"
exit 0
