# Regression test for live_objects counter drift on dormant chunks.
#
# Fixed in v0.13.0: the counter was not updated when a fully-free chunk
# was marked DORMANT during sweep, causing the invariant checker to flag
# a mismatch (actual=6502, reported=1).
# See CHANGELOG v0.13.0 Fixed.
#
# Trigger: allocate, free everything, collect. After sweep, the empty chunk
# goes DORMANT and live_objects must be 0 (or the runtime baseline).

require "../../src/gcry"
require "spec"

describe "Regression: live_objects counter drift on dormant chunks" do
  it "reports accurate live_objects after full free + collect" do
    heap = Gcry.default_heap

    # Allocate many small objects to fill a chunk
    ptrs = [] of Pointer(Void)
    10_000.times { ptrs << GC.malloc_atomic(32) }

    # Free everything
    ptrs.each { |p| GC.free(p) }
    ptrs.clear

    # Collect — the empty chunk should go DORMANT
    3.times { GC.collect }

    GC.collect

    m = Gcry.metrics(heap)
    # live_objects should be near 0 (Crystal runtime may keep a few)
    m.live_objects.should be < 100_u64
  end
end
