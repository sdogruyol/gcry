require "../../src/gcry"
require "spec"

# `GC_add_roots` (PR #44 review). Boehm takes its lock and keeps one entry per
# range: a range already inside a registered one is a no-op, one with the same
# start extends it (`GC_add_roots_inner`). Until 2026-10-07 gcry's
# `Gcry::CAbi.add_roots` read the table, built a copy one entry longer and
# published it with no lock: two threads adding at once each published a copy
# of the same old table, and one range was dropped — the collector stopped
# scanning it, and what it alone held was swept. Every call also appended,
# duplicates included, and left the previous table behind.

private BLOCK_BYTES =     256
private PATTERN     = 0x5D_u8
# Addresses kept for checking are XORed with this, so the kept word is not
# itself a conservative root for the block it names.
private MASK = 0x5555_5555_5555_5555_u64

private def live_and_intact?(hidden : UInt64) : Bool
  p = Pointer(Void).new(hidden ^ MASK)
  return false unless LibGC.base(p) == p
  BLOCK_BYTES.times { |i| return false unless p.as(UInt8*)[i] == PATTERN }
  true
end

# A block held only by *slot* (libc memory, never scanned by itself), made on
# a thread that is gone by the time this returns, so no stack holds it.
private def block_in(slot : Void**) : UInt64
  hidden = LibC.malloc(sizeof(UInt64)).as(UInt64*)
  Thread.new do
    p = LibGC.malloc_atomic(BLOCK_BYTES)
    p.as(UInt8*).fill(BLOCK_BYTES) { PATTERN }
    slot.value = p
    hidden.value = p.address ^ MASK
  end.join
  word = hidden.value
  LibC.free(hidden.as(Void*))
  word
end

private def collect_and_churn : Nil
  3.times do
    LibGC.collect
    # Over whatever the collection freed, so a reclaimed block reads zeros
    # rather than the pattern.
    2_000.times { LibGC.malloc_atomic(BLOCK_BYTES).as(UInt8*).clear(BLOCK_BYTES) }
  end
end

describe "GC_add_roots" do
  it "keeps one entry for a range added again, inside, or extended from its start" do
    words = 16
    buf = LibC.malloc(LibC::SizeT.new(words * sizeof(Void*))).as(Void**)
    buf.clear(words)
    before = Gcry::CAbi.root_range_count
    1000.times { LibGC.add_roots(buf.as(Void*), (buf + 8).as(Void*)) }
    Gcry::CAbi.root_range_count.should eq(before + 1)
    LibGC.add_roots((buf + 2).as(Void*), (buf + 5).as(Void*))
    Gcry::CAbi.root_range_count.should eq(before + 1)

    # Same start, further end: the one entry now covers word 12.
    hidden = block_in(buf + 12)
    LibGC.add_roots(buf.as(Void*), (buf + words).as(Void*))
    Gcry::CAbi.root_range_count.should eq(before + 1)
    collect_and_churn
    live_and_intact?(hidden).should be_true
  end

  it "keeps every range added by threads at once" do
    threads = 16
    rounds = 8
    rounds.times do
      before = Gcry::CAbi.root_range_count
      slots = LibC.malloc(LibC::SizeT.new(threads * sizeof(Void**))).as(Void***)
      hidden = LibC.malloc(LibC::SizeT.new(threads * sizeof(UInt64))).as(UInt64*)
      ready = Atomic(Int32).new(0)
      go = Atomic(Int32).new(0)
      workers = Array(Thread).new(threads) do |i|
        Thread.new do
          slot = LibC.malloc(sizeof(Void*)).as(Void**)
          p = LibGC.malloc_atomic(BLOCK_BYTES)
          p.as(UInt8*).fill(BLOCK_BYTES) { PATTERN }
          slot.value = p
          slots[i] = slot
          ready.add(1)
          until go.get != 0
            Intrinsics.pause
          end
          LibGC.add_roots(slot.as(Void*), (slot + 1).as(Void*))
          # `p` is used here, after the range holds the block: until then a
          # collection in another worker's allocation could sweep it. The
          # thread is gone before the collections below, and its stack with it.
          hidden[i] = p.address ^ MASK
        end
      end
      until ready.get == threads
        Thread.yield
      end
      go.set(1)
      workers.each(&.join)

      Gcry::CAbi.root_range_count.should eq(before + threads)
      collect_and_churn
      threads.times { |i| live_and_intact?(hidden[i]).should be_true }
      # The slots stay registered, so they stay allocated.
      LibC.free(slots.as(Void*))
      LibC.free(hidden.as(Void*))
    end
  end
end
