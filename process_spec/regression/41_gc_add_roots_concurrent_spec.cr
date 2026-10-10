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

  # Boehm's `GC_remove_roots` drops every range wholly inside its bounds and
  # no other (mark_rts.c). Until 2026-10-08 gcry did not define it.
  it "stops scanning a range GC_remove_roots takes back, and only that one" do
    words = 8
    buf = LibC.malloc(LibC::SizeT.new(words * sizeof(Void*))).as(Void**)
    buf.clear(words)
    before = Gcry::CAbi.root_range_count
    LibGC.add_roots(buf.as(Void*), (buf + 2).as(Void*))
    LibGC.add_roots((buf + 4).as(Void*), (buf + 6).as(Void*))
    Gcry::CAbi.root_range_count.should eq(before + 2)
    # Two blocks in the range taken back, one per word: a stale word in the
    # collect chain can keep one of them, as the other files here allow
    # (Windows x86_64 CI kept the one block this held, once). A range still
    # scanned keeps both.
    dropped = [block_in(buf), block_in(buf + 1)]
    kept = block_in(buf + 4)

    # Bounds that only partly cover the second range leave it alone.
    LibGC.remove_roots(buf.as(Void*), (buf + 5).as(Void*))
    Gcry::CAbi.root_range_count.should eq(before + 1)
    collect_and_churn
    live_and_intact?(kept).should be_true
    # The dropped range still holds the addresses; read on this frame only as
    # a masked comparison, the blocks themselves are gone or reused.
    dropped.count { |hidden| live_and_intact?(hidden) }.should be <= 1

    # The same start registered again is a root again.
    LibGC.add_roots(buf.as(Void*), (buf + 2).as(Void*))
    Gcry::CAbi.root_range_count.should eq(before + 2)
    revived = block_in(buf)
    collect_and_churn
    live_and_intact?(revived).should be_true
    LibGC.remove_roots(buf.as(Void*), (buf + words).as(Void*))
    Gcry::CAbi.root_range_count.should eq(before)
    LibC.free(buf.as(Void*))
  end

  # Boehm stores a range rounded inward to whole words and ignores one that
  # holds none (`GC_add_roots_inner`); `GC_remove_roots` compares against the
  # stored bounds. Until 2026-10-09 gcry kept the bounds as given, so the
  # word-aligned removal below left the range registered and scanned.
  it "rounds a range inward to whole words, as GC_remove_roots then sees it" do
    words = 8
    buf = LibC.malloc(LibC::SizeT.new(words * sizeof(Void*))).as(Void**)
    buf.clear(words)
    bytes = buf.as(UInt8*)
    before = Gcry::CAbi.root_range_count
    LibGC.add_roots((bytes + 1).as(Void*), (bytes + sizeof(Void*) + 4).as(Void*))
    Gcry::CAbi.root_range_count.should eq(before)

    LibGC.add_roots((bytes + 1).as(Void*), (bytes + 4 * sizeof(Void*) + 5).as(Void*))
    Gcry::CAbi.root_range_count.should eq(before + 1)
    LibGC.remove_roots((buf + 1).as(Void*), (buf + 4).as(Void*))
    Gcry::CAbi.root_range_count.should eq(before)
    LibC.free(buf.as(Void*))
  end

  # Boehm scans a registered range whole, whatever its length. Until
  # 2026-10-09 gcry pushed it through the stack scan's 64 MiB valve, so a
  # longer range was skipped every collection and what only it held was swept.
  it "scans a range longer than 64 MiB to its end" do
    bytes = 65_u64 * 1024 * 1024
    words = bytes // sizeof(Void*)
    buf = LibC.malloc(LibC::SizeT.new(bytes)).as(Void**)
    buf.clear(words)
    LibGC.add_roots(buf.as(Void*), (buf + words).as(Void*))
    hidden = block_in(buf + words - 1)
    collect_and_churn
    live_and_intact?(hidden).should be_true
    LibGC.remove_roots(buf.as(Void*), (buf + words).as(Void*))
    LibC.free(buf.as(Void*))
  end

  # Ranges added and removed over and over reuse the removed entries. A
  # table copy cannot free the one it replaces (the hook may be reading it),
  # and the first `GC_remove_roots` compacted a full table into a new copy:
  # 2M add/remove pairs over distinct ranges, one live at a time, left 45 MB
  # of copies behind.
  it "keeps the table's size to its live ranges under add/remove churn" do
    pairs = 100_000
    # One word per pair, so no range shares a start with an earlier one.
    buf = LibC.malloc(LibC::SizeT.new((pairs + 1) * sizeof(Void*))).as(Void**)
    buf.clear(pairs + 1)
    copies = Gcry::CAbi.root_table_copies
    pairs.times do |i|
      slot = buf + i
      LibGC.add_roots(slot.as(Void*), (slot + 1).as(Void*))
      LibGC.remove_roots(slot.as(Void*), (slot + 1).as(Void*))
    end
    (Gcry::CAbi.root_table_copies - copies).should be <= 1
    LibC.free(buf.as(Void*))
  end
end
