# Does a local variable stay a root while its frame spins?
#
# Found by accident: adding a watch loop to `bench/dormant_flush_race.cr` made
# its 40,000-element ballast array read back `size == 0` in every child, where
# the same binary without the loop read 40,000. The array is referenced by a
# local that is read inside the loop and again after it, so it is live across
# the whole loop by any definition — and gcry collected it anyway.
#
# The shape that matters is the *frame*, not the array: main holds a reference
# and stays in a tight loop while another thread collects. If that is enough to
# lose the reference then every root the mark takes from a stopped thread's
# stack is suspect, and the thread-list crash this tree has been chasing
# (`bench/log/linux/2026-08-23-threads-null-0x18/FINDINGS.md`) is one instance
# of it rather than a defect of its own.
require "../src/gcry"

ROUNDS   = (ENV["SPIN_ROUNDS"]?.try(&.to_i?) || 200)
ELEMENTS = (ENV["SPIN_ELEMENTS"]?.try(&.to_i?) || 40_000)

held = Array(Bytes).new(ELEMENTS)
ELEMENTS.times { held << Bytes.new(256) }
puts "spin-local-root: built #{held.size} elements"

done = Atomic(Int32).new(0)
collector = Thread.new do
  ROUNDS.times { GC.collect }
  done.set(1)
end

seen_min = held.size
until done.get == 1
  s = held.size
  seen_min = s if s < seen_min
end

collector.join

# Read it again after the loop, which is the read the compiler cannot elide.
final = held.size
if final == ELEMENTS && seen_min == ELEMENTS
  puts "spin-local-root: intact (#{final})"
else
  puts "spin-local-root: LOST — size read #{seen_min} during the spin, #{final} after; " \
       "a local live across the loop stopped being a root"
end
