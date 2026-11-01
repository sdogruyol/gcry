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

# Zeroes 64 KiB of dead stack below the caller's frame.
@[NoInline]
private def drift_scrub : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory" : "volatile")
end

# Allocate `count` blocks, free every one explicitly, collect, and report how
# far the counter came back.
private def drift_cycle(heap, count : Int32) : Cycle
  # Pre-size the pointer store *before* the baseline is taken: a growing Array
  # reallocates inside the measured window, and its final buffer is 80 KB at
  # count=10_000.
  ptrs = Array(Pointer(Void)).new(count)

  # Collect *before* the baseline. Everything allocated since process start that
  # is already garbage would otherwise be reclaimed by this cycle's collections
  # and counted as drift — downward, and by an amount that is whatever the spec
  # suite happened to leave lying around. Measured 2026-08-15: without this the
  # first cycle read -110 on x86_64 and -1007 on aarch64 / -1006 on darwin,
  # while a second cycle on the same process read -2, because the first cycle
  # had already done the cleaning.
  #
  # The dead frames below this one go first. A word an earlier example left
  # there can hold a dead object that has a finalizer, and with it everything
  # it reaches; the four collections leave it, and once the word is gone it
  # takes two more, one to run the finalizer and one to reclaim. When this
  # cycle's own calls overwrite the word, the reclaim lands between the
  # baseline and the check: count=10000 drift=-1457 and -1225 in 2 of 160
  # suite-order runs (2026-11-02, `87ccf4f4` block headers and the 0.40 tip
  # headerless on Crystal 1.22.2). A copy that scrubbed after the four
  # collections showed it in 1 run of 30: a fifth collection changed nothing,
  # the scrub's collection ran one finalizer and the next reclaimed 1 686
  # objects (`bench/log/linux/2026-11-02-scrub-band/`). Scrubbed first, the
  # four collections run the finalizer and reclaim before the baseline.
  drift_scrub
  4.times { GC.collect }
  # No collection between the baseline and the check: the arithmetic below
  # assumes none. A background one (`GCRY_IDLE_RELEASE_MS`) landing in this
  # window reclaimed the few objects made just before the baseline and read
  # 1-22 short of `baseline + count` in 23 of 30 runs at 5 ms, with every
  # rooted block intact (2026-09-23). `GC.disable` stops it, and allocation-
  # driven cycles with it.
  GC.disable
  begin
    baseline = Gcry.metrics(heap).live_objects
    count.times { ptrs << GC.malloc_atomic(32) }
    Gcry.metrics(heap).live_objects.should be >= baseline + count
  ensure
    GC.enable
  end

  ptrs.each { |p| GC.free(p) }
  ptrs.clear

  # Collect — the empty chunks should go DORMANT.
  4.times { GC.collect }

  Cycle.new(count, Gcry.metrics(heap).live_objects.to_i64 - baseline.to_i64)
end

# A walk-vs-counter verdict belongs here and is deliberately absent:
# `Gcry::Invariant.enable` is global and its checks run after *every* malloc and
# free, so turning it on inside a spec fires the documented off-by-one race
# (`actual=3458 reported=3459`) from an arbitrary allocation site and takes the
# process down. It answered the question it was added for on 2026-08-15 — the
# walk agreed, so the drift was never a counter defect — and comes back only
# behind `GCRY_DEBUG_INVARIANTS=1`, which is what the `make invariants` gate is.

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
    # Two counts an order of magnitude apart, because the first run under
    # `-Dgc_none` (2026-08-15) came back |drift| ≤ 4 on x86_64 and 1005 on
    # both aarch64 and darwin, and that spread had to be explained
    # before the bound could be trusted. It was: the drift was *negative* and
    # did not scale — the cycle's collections were reclaiming ambient garbage
    # left by everything that ran before, which is the collector working. The
    # pre-baseline collect in `drift_cycle` removes it. What survives here is a
    # failure that still means something, and reports which:
    #
    #   drift scales with count        → stranded per allocation
    #   drift flat across counts       → a fixed strand, one chunk's worth
    big = drift_cycle(heap, 10_000)
    small = drift_cycle(heap, 1_000)
    detail = "#{big} | #{small}"

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
