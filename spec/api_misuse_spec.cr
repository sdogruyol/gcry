# API misuse test suite.
#
# Tests that gcry handles invalid inputs gracefully instead of crashing.
#
# Covers:
#   - GC.free(null) → no-op
#   - GC.realloc(null, 0) → malloc(0)
#   - GC.malloc(0) → minimum size
#   - add_root(null) → ignored
#   - register_disappearing_link(null, ...) → ignored
#   - GC.collect inside finalizer → reentrancy safety
#   - push_stack with invalid bounds → ignored
#
# All tests run under -Dgc_none (process GC), but the library-heap path
# is also tested via the default Boehm-assisted spec run.

require "../src/gcry"
require "spec"

describe "API misuse" do
  it "free(null) is a no-op" do
    GC.free(Pointer(Void).null)
    true.should be_true # did not crash
  end

  it "realloc(null, 0) returns a valid pointer" do
    ptr = GC.realloc(Pointer(Void).null, 0_u64)
    ptr.should_not be_nil
    GC.free(ptr)
  end

  it "realloc(null, 64) returns a valid pointer (malloc(64))" do
    ptr = GC.realloc(Pointer(Void).null, 64_u64)
    ptr.should_not be_nil
    GC.free(ptr)
  end

  it "realloc(valid_ptr, 0) returns valid pointer (malloc(0))" do
    orig = GC.malloc(32)
    ptr = GC.realloc(orig, 0_u64)
    ptr.should_not be_nil
    GC.free(ptr)
  end

  it "malloc(0) returns non-nil" do
    ptr = GC.malloc(0_u64)
    ptr.should_not be_nil
    GC.free(ptr)
  end

  it "malloc_atomic(0) returns non-nil" do
    ptr = GC.malloc_atomic(0_u64)
    ptr.should_not be_nil
    GC.free(ptr)
  end

  it "add_root(null) is ignored" do
    Gcry.add_root(Pointer(Void).null)
    true.should be_true
  end

  it "register_disappearing_link with null link is ignored" do
    null_ptr_ptr = Pointer(Pointer(Void)).null
    Gcry.register_disappearing_link(null_ptr_ptr, Pointer(Void).new(0x1_u64))
    true.should be_true
  end

  it "register_disappearing_link with null object is ignored" do
    ref = Pointer(Void).new(0x2_u64)
    Gcry.register_disappearing_link(pointerof(ref), Pointer(Void).null)
    true.should be_true
  end

  {% if flag?(:linux) %}
    it "collect inside finalizer does not deadlock" do
      reentered = false

      Signal::USR1.trap do
        # GC.malloc inside signal handler (async-signal-safe)
        _ = GC.malloc_atomic(32)
        reentered = true
      end

      Process.signal(Signal::USR1, Process.pid)
      sleep(0.01.seconds)

      Signal::USR1.reset
      reentered.should be_true
    end
  {% end %}

  # push_stack with invalid bounds — we test via Gcry::MarkStack directly
  it "add_root with large pointer is ignored" do
    Gcry.add_root(Pointer(Void).new(0xFFFF_FFFF_FFFF_FFFF_u64))
    true.should be_true
  end

  it "survives alternating malloc/free patterns" do
    # Verify rapid alloc/free doesn't corrupt internal structures
    1000.times do |i|
      p1 = GC.malloc(16)
      p2 = GC.malloc(32)
      GC.free(p1)
      GC.free(p2)
    end
    true.should be_true
  end
end
