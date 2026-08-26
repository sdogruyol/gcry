# Does gcry see a reference that lives only in a class variable?
#
# `Thread.@@threads` is one, and the oldest open crash in this tree is
# `stop_world` reading a null out of the object it points at
# (`bench/log/linux/2026-08-23-threads-null-0x18/FINDINGS.md`). A class variable
# is not a root gcry is told about: it is found by parsing `/proc/self/maps` and
# guessing which anonymous mapping is the executable's BSS from its adjacency to
# the previous file-backed RW mapping (`src/gcry/platform/linux_roots.cr`). If
# that guess misses, an object held only there is unreachable, and a
# conservative scan keeps it alive only for as long as some stale stack slot or
# register happens to hold its address — which is exactly the shape of a defect
# that shows up in a few percent of runs and moves with the machine.
#
# So: stash an object in a class variable, drop every other reference, collect,
# and read it back. The pattern is checked rather than the pointer, because the
# failure being looked for is the block being handed out again — the reference
# stays valid-looking and the bytes underneath change.
require "../src/gcry"

class Stash
  @@held : Bytes? = nil
  @@marker : String? = nil

  def self.fill : Nil
    b = Bytes.new(4096)
    i = 0
    while i < b.size
      b[i] = 0xAB_u8
      i += 1
    end
    @@held = b
    @@marker = "gcry-static-root-probe-#{b.size}"
  end

  def self.damaged? : Bool
    b = @@held
    return true if b.nil?
    i = 0
    while i < b.size
      return true if b[i] != 0xAB_u8
      i += 1
    end
    m = @@marker
    return true if m.nil? || m != "gcry-static-root-probe-4096"
    false
  end
end

# Fill from its own frame so the stack slot that held the object goes out of
# scope before anything collects.
Stash.fill

ROUNDS = (ENV["STATIC_ROOT_ROUNDS"]?.try(&.to_i?) || 200)

# Churn hard enough that a freed block is handed out again rather than merely
# freed. Without the churn a missed root reads back intact and the probe says
# "fine" about a heap that has already lost the object.
damaged_at = -1
ROUNDS.times do |round|
  1000.times do
    buf = Bytes.new(256)
    buf[0] = 1_u8
  end
  GC.collect
  if Stash.damaged?
    damaged_at = round
    break
  end
end

heap = Gcry.default_heap
if damaged_at >= 0
  puts "static-root-classvar: DAMAGED at round #{damaged_at} — a class variable is not keeping its object alive"
else
  puts "static-root-classvar: intact after #{ROUNDS} rounds, collections #{heap.collections}"
end
