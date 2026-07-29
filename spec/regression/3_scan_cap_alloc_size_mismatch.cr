# Regression test for layout scan_cap requiring alloc_size match.
#
# Fixed in v0.12.0: on size mismatch (raw buffer whose leading Int32
# collided with a registered type_id), the old path still applied that
# type's scan_cap and returned — truncating the mark scan and dropping
# live pointers (acikturkiye SEGV with layouts on).
# See CHANGELOG v0.12.0 Fixed.
#
# Trigger: allocate a raw buffer (no Crystal type) whose first word happens
# to look like a type_id, then verify GC doesn't truncate the mark scan.

require "../../src/gcry"
require "spec"

describe "Regression: layout scan_cap / alloc_size mismatch" do
  it "survives raw buffer with type_id collision" do
    # Allocate a raw buffer; its first word is garbage but may collide
    # with a registered type_id. The GC must fall through to full
    # conservative scan instead of applying a mismatched scan_cap.
    buf = GC.malloc_atomic(256)

    # Write a plausible type_id into the first word
    buf.as(Int32*).value = 0x7ABC

    # Write a pointer into the buffer to ensure mark scan doesn't truncate
    keep = GC.malloc_atomic(64)

    # 5 collections — should not SEGV
    5.times { GC.collect }

    # Verify the buffer contents survive
    buf.as(Int32*).value.should eq(0x7ABC)
  end
end
