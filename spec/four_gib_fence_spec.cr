require "./spec_helper"

# No heap mapping may cover the address space around a 4 GiB boundary
# (`Gcry.os_map_placed`, `Gcry.os_reserve_placed`).
#
# A 32-bit store over a stack slot that held a heap pointer leaves
# `0xHHHH00000001`: the 4 GiB boundary at or below the heap, plus a small
# number. On Linux x86-64 the vDSO's `clock_gettime` leaves one in the
# collector's own frame at every collection, and crystal-metric's frames hold
# `0xHHHH00000000`; whichever large block covered the boundary was kept by
# it. That was JsonGenerate's peak landing on fixed high levels at random
# reps on every runner (`bench/log/macos/2026-10-23-jsongen-m1/`).
#
# Each example asks the kernel for a mapping across a boundary
# (`Gcry.map_hint`, over address space it just gave back) and checks where
# the mapping ended up. The control arms, the fence off, prove the hint
# lands there, so the fixed arms test the placement and not the kernel's
# luck. Linux and macOS take a free hint; Windows takes an address as a
# demand, so the mapping examples do not run there.

private FENCE = Gcry::FOUR_GIB_FENCE

# A 4 GiB boundary with at least 128 MiB free below it and `span - 4 GiB -
# 128 MiB` above: inside an address range the kernel handed out and has taken
# back.
private def free_boundary(span : UInt64 = Gcry::FOUR_GIB &* 2) : UInt64
  at = Gcry::OS.mmap(Pointer(Void).null, LibC::SizeT.new(span), Gcry::OS::PROT_NONE,
    Gcry::OS::MAP_PRIVATE | Gcry::OS::MAP_ANONYMOUS, -1, 0)
  Gcry.mmap_failed?(at).should be_false
  Gcry::OS.munmap(at, LibC::SizeT.new(span))
  (at.address &+ (128_u64 << 20) &+ (Gcry::FOUR_GIB &- 1)) & ~(Gcry::FOUR_GIB &- 1)
end

# `[at, at + len)` enters the window around boundary *b*.
private def in_window?(at : UInt64, len : UInt64, b : UInt64) : Bool
  at < b &+ FENCE && at &+ len > b &- FENCE
end

# The hint stands for where the kernel would put a mapping. On macOS a heap
# mapping is asked for at the high base instead (`Gcry.high_heap_base`),
# where no hint reaches it, so the placement is off for the block: these
# examples test the fence wherever the kernel answers.
private def with_hint(at : UInt64, &)
  Gcry.map_hint = at
  {% if flag?(:darwin) %}
    high = Gcry.high_heap?
    Gcry.high_heap = false
  {% end %}
  begin
    yield
  ensure
    Gcry.map_hint = 0_u64
    {% if flag?(:darwin) %}
      Gcry.high_heap = high
    {% end %}
  end
end

# The large chunk holding *user*, as `{base, mapped bytes}`.
private def large_span(heap : Gcry::Heap, user : Void*) : {UInt64, UInt64}
  span = {0_u64, 0_u64}
  heap.each_chunk do |chunk|
    next unless Gcry::ChunkHeader.large?(chunk)
    next unless Gcry::ChunkHeader.large_user(chunk) == user
    span = {chunk.address, chunk.value.mapped_bytes}
  end
  span
end

describe "Gcry.four_gib_window" do
  it "names the window a range enters, and nothing for a range beside it" do
    g = Gcry::FOUR_GIB
    b = 5_u64 &* g
    Gcry.four_gib_window(b &- 4096, 8192).should eq({b &- FENCE, b &+ FENCE})
    Gcry.four_gib_window(b &+ 1, 4096).should eq({b &- FENCE, b &+ FENCE})
    Gcry.four_gib_window(b &- FENCE, 4096).should eq({b &- FENCE, b &+ FENCE})
    Gcry.four_gib_window(b &+ FENCE &- 4096, 4096).should eq({b &- FENCE, b &+ FENCE})
    # Ending where the window starts, starting where it ends: outside.
    Gcry.four_gib_window(b &- FENCE &- 4096, 4096).should eq({0_u64, 0_u64})
    Gcry.four_gib_window(b &+ FENCE, 4096).should eq({0_u64, 0_u64})
    # Below the next boundary: `0xHHHHFFFFFFFF` is a negative store's word.
    Gcry.four_gib_window(b &+ g &- 4096, 4096).should eq({b &+ g &- FENCE, b &+ g &+ FENCE})
    # Between two windows, however long.
    Gcry.four_gib_window(b &+ FENCE, g &- 2_u64 &* FENCE).should eq({0_u64, 0_u64})
    # Too long to fit between two: left alone.
    Gcry.four_gib_window(b &+ FENCE, g).should eq({0_u64, 0_u64})
    # The window at 0, where small integers point.
    Gcry.four_gib_window(65536, 4096).should eq({0_u64, FENCE})
  end
end

# Gives back an `os_reserve` reservation as `Heap` does, the count with it.
private def release_reservation(ptr : Void*, extent : UInt64, commit : UInt64) : Nil
  Gcry.os_release_reserved(ptr + commit, extent &- commit)
  Gcry.os_unmap(ptr, commit)
end

describe "4 GiB fence" do
  it "keeps a large block off a 4 GiB boundary, which an unfenced heap maps across" do
    pending! "Windows takes an address as a demand, not a hint" if {{ flag?(:win32) }}
    payload = 32_u64 << 20
    {false, true}.each do |fenced|
      b = free_boundary
      heap = Gcry::Heap.new
      begin
        heap.gc_threshold = UInt64::MAX
        Gcry.four_gib_fence = fenced
        # Everything the first allocation maps besides its chunk, mapped now.
        heap.malloc(payload).null?.should be_false
        fences = Gcry.four_gib_fences
        user = with_hint(b &- (payload >> 1)) { heap.malloc(payload) }
        user.null?.should be_false
        at, len = large_span(heap, user)
        len.should be > payload
        # What a half-overwritten stack word holds: the boundary plus a
        # small number, or minus one.
        hit = heap.find_block(Pointer(Void).new(b &+ 1))
        below = heap.find_block(Pointer(Void).new(b &- 1))
        if fenced
          in_window?(at, len, b).should be_false
          hit.should be_nil
          below.should be_nil
          Gcry.four_gib_fences.should be > fences
        else
          # The control: the hint put the block across the boundary, and the
          # word names it.
          (at <= b && b < at &+ len).should be_true
          hit.should_not be_nil
          below.should_not be_nil
        end
      ensure
        Gcry.four_gib_fence = true
        heap.destroy
      end
    end
  end

  it "keeps a chunk-sized mapping out of the window, not only off the boundary" do
    pending! "Windows takes an address as a demand, not a hint" if {{ flag?(:win32) }}
    bytes = Gcry::Heap::SMALL_CHUNK_BYTES
    b = free_boundary
    # Wholly inside the window, above the boundary: `0xHHHH00012345`.
    ptr = with_hint(b &+ 65536) { Gcry.os_map(bytes) }
    ptr.address.should eq(b &+ 65536)
    Gcry.os_unmap(ptr, bytes)

    b = free_boundary
    remaps = Gcry.four_gib_remaps
    ptr = with_hint(b &+ 65536) { Gcry.os_map_placed(bytes) }
    Gcry.mmap_failed?(ptr).should be_false
    in_window?(ptr.address, bytes, b).should be_false
    Gcry.four_gib_remaps.should be > remaps
    Gcry.os_unmap(ptr, bytes)
  end

  it "keeps a growth reservation off a 4 GiB boundary, room included" do
    pending! "Windows takes an address as a demand, not a hint" if {{ flag?(:win32) }}
    commit = 1_u64 << 20
    extent = 64_u64 << 20
    # The committed front ends below the window; the room crosses it, and a
    # block grows into its room where it stands (`Heap#grow_large`).
    b = free_boundary
    ptr = with_hint(b &- FENCE &- commit) { Gcry.os_reserve(extent, commit) }
    ptr.address.should eq(b &- FENCE &- commit)
    release_reservation(ptr, extent, commit)

    b = free_boundary
    ptr = with_hint(b &- FENCE &- commit) { Gcry.os_reserve_placed(extent, commit) }
    ptr.null?.should be_false
    in_window?(ptr.address, extent, b).should be_false
    release_reservation(ptr, extent, commit)
  end

  it "places the committed front of a reservation too long to place whole" do
    pending! "Windows takes an address as a demand, not a hint" if {{ flag?(:win32) }}
    commit = 64_u64 << 20
    # What `realloc` reserves past a block of just over 1 GiB: its data
    # rounded up to 2 GiB and doubled, one page more.
    extent = Gcry::FOUR_GIB &+ 65536
    span = Gcry::FOUR_GIB &* 3
    # The front across the boundary.
    b = free_boundary(span)
    ptr = with_hint(b &- (commit >> 1)) { Gcry.os_reserve(extent, commit) }
    ptr.address.should eq(b &- (commit >> 1))
    release_reservation(ptr, extent, commit)

    b = free_boundary(span)
    ptr = with_hint(b &- (commit >> 1)) { Gcry.os_reserve_placed(extent, commit) }
    ptr.null?.should be_false
    Gcry.four_gib_window(ptr.address, commit).should eq({0_u64, 0_u64})
    release_reservation(ptr, extent, commit)
  end

  it "leaves a mapping beside a window where the kernel put it" do
    pending! "Windows takes an address as a demand, not a hint" if {{ flag?(:win32) }}
    bytes = Gcry::Heap::SMALL_CHUNK_BYTES
    b = free_boundary
    remaps = Gcry.four_gib_remaps
    ptr = with_hint(b &+ FENCE) { Gcry.os_map_placed(bytes) }
    ptr.address.should eq(b &+ FENCE)
    Gcry.four_gib_remaps.should eq(remaps)
    Gcry.os_unmap(ptr, bytes)
  end
end
