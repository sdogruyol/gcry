# Regression test for live_objects counter drift on dormant chunks.
#
# Fixed in v0.14.0: the counter was not updated when a fully-free chunk
# was marked DORMANT during sweep, causing the invariant checker to flag
# a mismatch (actual=6502, reported=1).
# See CHANGELOG v0.14.0 Fixed.
#
# Trigger: allocate, free everything, collect. After sweep, the empty chunk
# goes DORMANT and live_objects must be 0 (or the runtime baseline).

require "../../src/gcry"
require "spec"

describe "Regression: live_objects counter drift on dormant chunks" do
  it "returns live_objects to its baseline after full free + collect" do
    heap = Gcry.default_heap

    # The baseline, not zero. This spec asserted `live_objects < 100` until
    # 2026-08-15, and passed — from `spec/`, where it ran under Boehm, so gcry's
    # heap held nothing and the bound was vacuous. Under `-Dgc_none` the whole
    # runtime lives in this heap and the ambient count is ~150. What the v0.14.0
    # defect actually did was strand the *allocated* objects in the counter when
    # their chunk went dormant, so the number to assert is the delta.
    baseline = Gcry.metrics(heap).live_objects

    count = 10_000
    ptrs = [] of Pointer(Void)
    count.times { ptrs << GC.malloc_atomic(32) }
    Gcry.metrics(heap).live_objects.should be >= baseline + count

    ptrs.each { |p| GC.free(p) }
    ptrs.clear

    # Collect — the empty chunks should go DORMANT.
    4.times { GC.collect }

    after = Gcry.metrics(heap).live_objects
    drift = after.to_i64 - baseline.to_i64
    # Slack for whatever the spec framework itself allocated while running; the
    # defect this pins was 10 000 wide.
    drift.abs.should be < 500
  end
end
