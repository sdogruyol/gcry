require "./spec_helper"

# A conservative collector's whole safety argument is that its scan sees
# *every* pointer-aligned word of a root range. Nothing else in the suite
# held it: stepping the scan cursor two words at a time instead of one
# passed all 291 examples (2026-09-09), and a root the scan skips is an
# object freed while live. That perturbation is `bench/mutations` mutant 09,
# which is red against this file and green without it.
#
# Both entry points are asserted because they align and walk separately
# (`scan_range`, and the chunked `scan_range_chunked` the static-root and
# large-object paths call), each in `safe` and unsafe mode because the safe
# path re-derives its bounds per readable region. The unaligned case is here
# because the bounds a real caller passes — a stack low-water mark, a PE
# section, an object body — are not word-aligned in general.
private def each_word_seen(low : UInt64*, words : Int32, safe : Bool, chunked : Bool) : Array(UInt64)
  seen = [] of UInt64
  from = low.as(Void*)
  to = (low + words).as(Void*)
  if chunked
    Gcry::Roots.scan_range_chunked(from, to, safe: safe) { |c| seen << c.address }
  else
    Gcry::Roots.scan_range(from, to, safe: safe) { |c| seen << c.address }
  end
  seen
end

describe "conservative scan completeness" do
  # Distinct, recognisable, non-zero values so a skipped slot is visible as a
  # missing value rather than as a count that happens to match.
  words = 64
  buffer = Pointer(UInt64).malloc(words)
  words.times { |i| buffer[i] = 0xA5A5_0000_u64 + i }
  want = Array.new(words) { |i| 0xA5A5_0000_u64 + i }

  {% for chunked in [false, true] %}
    {% for safe in [false, true] %}
      it "yields every aligned word (chunked: {{chunked}}, safe: {{safe}})" do
        each_word_seen(buffer, words, safe: {{safe}}, chunked: {{chunked}}).should eq want
      end
    {% end %}
  {% end %}

  it "yields nothing for an empty or inverted range" do
    empty = buffer.as(Void*)
    Gcry::Roots.scan_range(empty, empty) { fail "scanned an empty range" }
    # Reversed bounds are normalised, not walked backwards: the same words,
    # once each, in the same order.
    seen = [] of UInt64
    Gcry::Roots.scan_range((buffer + words).as(Void*), buffer.as(Void*)) { |c| seen << c.address }
    seen.should eq want
  end

  it "scans a range whose bounds are not word-aligned inclusively" do
    # One byte in from each end: the first whole word starts after `low` and
    # the last whole word ends before `high`, so 62 of the 64 are in range.
    from = (buffer.as(UInt8*) + 1).as(Void*)
    to = ((buffer + words).as(UInt8*) - 1).as(Void*)
    seen = [] of UInt64
    Gcry::Roots.scan_range(from, to) { |c| seen << c.address }
    seen.should eq want[1..-2]
  end
end
