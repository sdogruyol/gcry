require "../../src/gcry"
require "spec"

# The mprotect page barrier's cards cover the heap span as it was at the arm
# (`arm_mprotect_on_old_chunks`: `mprotect_set_heap_range(@heap_min,
# @heap_max)`), and the dirty-page scan of every minor and of an incremental
# cycle's termination (`Heap#scan_mprotect_pages`) runs against them after
# the chunk set has moved on. Until 2026-11-02 it went wrong two ways, each
# killing the collection with "Invalid memory access":
#
# - *outside*: the scan protects the old chunks again afterwards, walking
#   the chunks as they are by then. A chunk mapped since the arm can lie
#   outside the cards — a large allocation gets a mapping of its own, and on
#   Linux the kernel places new mappings below the existing ones — and it
#   was made read-only all the same, with no protected bit anywhere
#   (`mprotect_protect_range` set only the bits inside the cards and
#   protected the whole range). The sweep of the same collection wrote its
#   header (the chunk-list rebuild, `ChunkHeader.link`; under an
#   incremental cycle's last slice, a new small chunk's occupancy bitmap),
#   the fault had no card to claim it, and the handler handed it to
#   Crystal's. Now the re-protect replaces cards the heap has outgrown, and
#   `mprotect_protect_range` never protects outside the cards.
# - *stale*: the scan read every dirty page in the cards. A page of a
#   cached large chunk is dirtied when the chunk is unlinked from the cache
#   and stays dirty after the chunk is unmapped (`trim_large_cache`, which
#   the allocation path runs between collections), so the scan read a page
#   with nothing mapped. Now it reads the dirty pages of the chunks the heap
#   holds.
#
# Each construction runs the nursery with the mprotect barrier and a minor
# to arm it. *outside*: a large block big enough that no hole inside the
# cards holds it, freed into the large cache, then a second minor.
# *stale*: a large block held across the arm, freed (its first page
# dirtied), the cache trimmed to nothing (unmapped), then a second minor.
# Each control arm (`Gcry::Platform.mprotect_cards_cover_protection`,
# `mprotect_dirty_scan_by_chunk` = false, the code before) must die in that
# minor, or the fixed arm passes on nothing. Every arm runs in a process of
# its own. A child that cannot build its construction — no nursery (the
# headerless layout), no mprotect barrier (Linux only), the block inside the
# cards after all, the free not cached or not dirtying — says so and the
# parent accepts it. `bench/log/linux/2026-11-02-nursery-mprotect/FINDINGS.md`.

private MPROTECT99_SKIP_MARK  = "mprotect99: this heap cannot reach the window, skipped"
private MPROTECT99_FIXED_MARK = "mprotect99: the second minor returned"
# Larger than any hole the spec runner's heap has when the child starts.
private MPROTECT99_OUTSIDE_BYTES = 16 * 1024 * 1024
private MPROTECT99_STALE_BYTES   = 1 * 1024 * 1024

# Held across the arm: a class variable is a static root.
private class Mprotect99Hold
  class_property block = Pointer(Void).null
end

private def mprotect99_say(text : String) : Nil
  STDOUT.puts text
  STDOUT.flush
end

private def mprotect99_page(addr : UInt64) : UInt64
  {% if flag?(:linux) %}
    addr & ~(Gcry::Platform::PAGE - 1)
  {% else %}
    addr
  {% end %}
end

# The nursery on with the mprotect barrier, armed by a minor. False when
# this heap has neither.
private def mprotect99_arm(heap : Gcry::Heap) : Bool
  heap.prefer_mprotect_barrier = true
  heap.nursery_enabled = true
  return false unless heap.nursery_enabled
  heap.minor_collect
  heap.barrier_backend_name == "mprotect"
end

private def mprotect99_outside : Nil
  {% if flag?(:linux) && flag?(:gcry_block_headers) %}
    heap = Gcry.default_heap
    return mprotect99_say("#{MPROTECT99_SKIP_MARK}: no nursery or no mprotect barrier") unless mprotect99_arm(heap)
    block = GC.malloc(MPROTECT99_OUTSIDE_BYTES)
    low = block.address
    if Gcry::Platform.mprotect_cards_cover?(low, low + MPROTECT99_OUTSIDE_BYTES.to_u64)
      return mprotect99_say("#{MPROTECT99_SKIP_MARK}: the block landed inside the cards")
    end
    # Freed into the large cache, as the report's 300 000 bytes were; the
    # default retain (4 MiB) would unmap a block this big at once. Kept live
    # instead, it does not reach the window in this runner: the sweep wrote
    # no header of it.
    heap.large_cache_retain = 2_u64 * MPROTECT99_OUTSIDE_BYTES
    cached = heap.large_free_bytes
    GC.free(block)
    return mprotect99_say("#{MPROTECT99_SKIP_MARK}: the free did not cache the chunk") unless heap.large_free_bytes > cached
    mprotect99_say("mprotect99 outside: a freed large chunk lies below or above the arm's cards")
    # Scans the dirty pages, protects the old chunks again, sweeps.
    heap.minor_collect
    mprotect99_say(MPROTECT99_FIXED_MARK)
  {% else %}
    mprotect99_say("#{MPROTECT99_SKIP_MARK}: Linux with -Dgcry_block_headers only")
  {% end %}
end

private def mprotect99_stale : Nil
  {% if flag?(:linux) && flag?(:gcry_block_headers) %}
    heap = Gcry.default_heap
    Mprotect99Hold.block = GC.malloc(MPROTECT99_STALE_BYTES)
    return mprotect99_say("#{MPROTECT99_SKIP_MARK}: no nursery or no mprotect barrier") unless mprotect99_arm(heap)
    block = Mprotect99Hold.block
    Mprotect99Hold.block = Pointer(Void).null
    low = mprotect99_page(block.address)
    high = block.address + MPROTECT99_STALE_BYTES.to_u64
    cached = heap.large_free_bytes
    # Links the chunk into the cache: a write to its protected first page.
    GC.free(block)
    dirty = false
    Gcry::Platform.each_mprotect_dirty_page(low, high) { dirty = true }
    unless dirty && heap.large_free_bytes > cached
      return mprotect99_say("#{MPROTECT99_SKIP_MARK}: the free did not cache or dirty the chunk")
    end
    heap.trim_large_cache(0_u64, defer: false)
    return mprotect99_say("#{MPROTECT99_SKIP_MARK}: the trim left the cache") unless heap.large_free_bytes == 0
    mprotect99_say("mprotect99 stale: a dirtied large chunk is unmapped")
    heap.minor_collect
    mprotect99_say(MPROTECT99_FIXED_MARK)
  {% else %}
    mprotect99_say("#{MPROTECT99_SKIP_MARK}: Linux with -Dgcry_block_headers only")
  {% end %}
end

# Runs one child; kills it past *seconds*. Returns its status and output.
private def mprotect99_child(arm : String, seconds : Int32 = 90) : {Process::Status, String}
  captured = IO::Memory.new
  child = Process.new(Process.executable_path.not_nil!, ["-e", "mprotect-outside-cards child #{arm}"],
    env: {"GCRY_MPROTECT99_CHILD" => arm}, output: captured, error: captured)
  deadline = Time.instant + seconds.seconds
  until child.terminated? || Time.instant >= deadline
    sleep 100.milliseconds
  end
  child.terminate(graceful: false) unless child.terminated?
  status = child.wait
  {status, captured.to_s}
end

private def mprotect99_expect_fixed(arm : String) : Nil
  status, text = mprotect99_child(arm)
  fail "child #{arm} #{status.inspect}:\n#{text}" unless status.success?
  text.should contain("1 examples, 0 failures")
  text.should contain(MPROTECT99_FIXED_MARK) unless text.includes?(MPROTECT99_SKIP_MARK)
end

# The handler forwards the fault to Crystal's handler, which prints and
# exits with the signal number.
private def mprotect99_expect_death(arm : String, reached : String) : Nil
  status, text = mprotect99_child(arm)
  return if status.success? && text.includes?(MPROTECT99_SKIP_MARK)
  text.should contain(reached)
  fail "the control arm survived:\n#{text}" if status.success?
  text.should contain("Invalid memory access")
  text.should_not contain(MPROTECT99_FIXED_MARK)
end

describe "Regression: the mprotect dirty-page scan against a chunk set that moved since the arm" do
  it "outside: fixed arm in a process of its own" do
    mprotect99_expect_fixed("outside-fixed")
  end

  it "outside: control arm protects a chunk no card covers and dies" do
    mprotect99_expect_death("outside-control", "mprotect99 outside: a freed large chunk lies")
  end

  it "stale: fixed arm in a process of its own" do
    mprotect99_expect_fixed("stale-fixed")
  end

  it "stale: control arm reads an unmapped dirty page and dies" do
    mprotect99_expect_death("stale-control", "mprotect99 stale: a dirtied large chunk is unmapped")
  end

  it "mprotect-outside-cards child outside-fixed" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "outside-fixed"
    mprotect99_outside
  end

  it "mprotect-outside-cards child outside-control" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "outside-control"
    {% if flag?(:linux) %}
      Gcry::Platform.mprotect_cards_cover_protection = false
    {% end %}
    mprotect99_outside
  end

  it "mprotect-outside-cards child stale-fixed" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "stale-fixed"
    mprotect99_stale
  end

  it "mprotect-outside-cards child stale-control" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "stale-control"
    {% if flag?(:linux) %}
      Gcry::Platform.mprotect_dirty_scan_by_chunk = false
    {% end %}
    mprotect99_stale
  end
end
