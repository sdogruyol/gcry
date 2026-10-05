require "../../src/gcry"
require "spec"

# Crystal decides per method whether a call to it can raise, and emits
# `invoke` (with a landing pad) only for those. The flag is propagated once,
# while the cleanup pass walks call targets, so a method first reached through
# a call cycle can be left marked as not raising for good, and a `rescue`
# around a call to it never sees the exception.
#
# With the collector written in Crystal, `String::Builder` → `GC.malloc_atomic`
# → gcry → `RuntimeError.from_os_error` → `Errno#message` →
# `String.new(Slice)` → `String.new(Pointer(UInt8), Int32)` closes such a cycle
# through `String.new(chars, bytesize, size)`, whose own message interpolation
# builds a String. `String.new(Pointer(UInt8).null, 3)` then raised past every
# `rescue` (`spec/std/string_spec.cr:2237` in Crystal's own suite).
# `bench/log/linux/2026-10-05-raises-cycle/`.
describe "rescue around a String.new that raises" do
  it "catches the ArgumentError for a null pointer with a nonzero size" do
    expect_raises(ArgumentError, "Cannot create a string with a null pointer and a non-zero (3) bytesize") do
      String.new(Pointer(UInt8).null, 3)
    end
  end
end
