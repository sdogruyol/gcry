# Is the storage of a class variable inside a range gcry scans as a root?
#
# gcry does not get told where the executable's globals are. It parses
# `/proc/self/maps` and decides that an anonymous RW mapping is BSS when it
# begins exactly where the previous file-backed RW mapping of the main
# executable ended (`src/gcry/platform/linux_roots.cr`). Class variables live
# there, `Thread.@@threads` among them, and if the guess misses then everything
# reachable only through a class variable is garbage as far as the mark is
# concerned — kept alive, most of the time, by nothing but a stale stack slot.
#
# This asks the question directly rather than through a race: take the address
# of a class variable's storage and look for it in the ranges gcry would scan.
require "../src/gcry"

class Probe
  @@held : Bytes? = nil
  @@second : String? = nil

  def self.slot_addr : UInt64
    pointerof(@@held).address
  end

  def self.second_addr : UInt64
    pointerof(@@second).address
  end

  def self.fill : Nil
    @@held = Bytes.new(64)
    @@second = "probe"
  end
end

Probe.fill

slots = {"@@held" => Probe.slot_addr, "@@second" => Probe.second_addr}

ranges = [] of Tuple(UInt64, UInt64)
Gcry::Platform.scan_static_roots do |low, high|
  ranges << {low.address, high.address}
end

puts "static roots: #{ranges.size} ranges, #{ranges.sum { |r| r[1] - r[0] }} bytes"
slots.each do |name, addr|
  covered = ranges.any? { |r| addr >= r[0] && addr < r[1] }
  puts "  #{name} slot 0x#{addr.to_s(16)} covered=#{covered}"
end
