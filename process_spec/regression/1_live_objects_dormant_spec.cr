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

private record Cycle, count : Int32, drift : Int64 do
  def to_s(io : IO) : Nil
    io << "count=" << count << " drift=" << drift
  end
end

# Allocate `count` blocks, free every one explicitly, collect, and report how
# far the counter came back.
private def drift_cycle(heap, count : Int32) : Cycle
  # Pre-size the pointer store *before* the baseline is taken: a growing Array
  # reallocates inside the measured window, and its final buffer is 80 KB at
  # count=10_000.
  ptrs = Array(Pointer(Void)).new(count)
  baseline = Gcry.metrics(heap).live_objects

  count.times { ptrs << GC.malloc_atomic(32) }
  Gcry.metrics(heap).live_objects.should be >= baseline + count

  ptrs.each { |p| GC.free(p) }
  ptrs.clear

  # Collect — the empty chunks should go DORMANT.
  4.times { GC.collect }

  Cycle.new(count, Gcry.metrics(heap).live_objects.to_i64 - baseline.to_i64)
end

# Ask gcry's own checker whether the counter matches a walk of the heap. The
# walk skips dormant chunks, so this separates the two ways a drift can happen:
# a counter that stranded objects when their chunk went dormant reads high
# against the walk, while objects that are genuinely still live do not.
private def walk_verdict(heap) : String
  skips_before = Gcry::Invariant.concurrent_skips
  Gcry::Invariant.enable
  begin
    Gcry::Invariant.check_live_objects(heap)
  rescue ex
    return ex.message || "walk raised without a message"
  ensure
    Gcry::Invariant.disable
  end
  if Gcry::Invariant.concurrent_skips > skips_before
    "walk skipped — a second mutator was live, so the check says nothing"
  else
    "walk agrees with the counter"
  end
end

describe "Regression: live_objects counter drift on dormant chunks" do
  it "returns live_objects to its baseline after full free + collect" do
    heap = Gcry.default_heap

    # The baseline, not zero. This spec asserted `live_objects < 100` until
    # 2026-08-15, and passed — from `spec/`, where it ran under Boehm, so gcry's
    # heap held nothing and the bound was vacuous. Under `-Dgc_none` the whole
    # runtime lives in this heap and the ambient count is ~150. What the v0.14.0
    # defect actually did was strand the *allocated* objects in the counter when
    # their chunk went dormant, so the number to assert is the delta.
    #
    # Two counts an order of magnitude apart, plus the walk, because the first
    # run under `-Dgc_none` (2026-08-15) came back |drift| ≤ 4 on x86_64 and
    # 1005 on both aarch64 and darwin. A slack argument cannot explain a spread
    # that wide, so a failure here reports what tells the readings apart:
    #
    #   drift scales with count        → stranded per allocation
    #   drift flat across counts       → a fixed strand, one chunk's worth
    #   walk disagrees with counter    → the v0.14.0 defect's shape, in the
    #                                    counter and not in the heap
    #   walk agrees with counter       → the blocks really are still live, i.e.
    #                                    a free that did not free
    big = drift_cycle(heap, 10_000)
    small = drift_cycle(heap, 1_000)
    detail = "#{big} | #{small} | #{walk_verdict(heap)}"

    # Ambient allocation by the spec framework is single digits, measured; the
    # defect this pins was 10 000 wide. 500 sits well clear of both.
    big.drift.abs.should(be < 500, detail)
    small.drift.abs.should(be < 500, detail)

    # Arch-independent statement of the same defect: stranding is proportional
    # to what was allocated, so a ninefold count difference would show here even
    # on a host whose ambient floor were high enough to swallow the bound above.
    (big.drift - small.drift).abs.should(be < 500, detail)
  end
end
