# Crystal (1.21.0 at least) marks a method as raising while its cleanup pass
# walks call targets, once per method. A method first reached through a call
# cycle can be left marked as not raising, and calls to it are then emitted
# without a landing pad: a `rescue` around them never runs. Stock Boehm builds
# have such methods too (`5.clamp(...3)` escapes its `rescue`); see
# `bench/log/linux/2026-10-05-raises-cycle/`.
#
# The collector being Crystal code adds cycles: `String::Builder` →
# `GC.malloc_atomic` → gcry → `RuntimeError.from_os_error` → `Errno#message` →
# `String.new(Slice)` → `String.new(Pointer(UInt8), Int32)` → back into
# `String.new(chars, bytesize, size)`, whose error message builds a String.
# That left `String.new(Pointer(UInt8).null, 3)` uncatchable.
#
# `@[Raises]` sets the flag when the method is defined, before the cleanup
# pass, so no cycle can leave it unset. Shard-only workaround until the
# compiler propagates the flag to a fixpoint (patch in the findings above).
class String
  @[Raises]
  def self.new(chars : UInt8*, bytesize, size = 0)
    previous_def
  end
end
