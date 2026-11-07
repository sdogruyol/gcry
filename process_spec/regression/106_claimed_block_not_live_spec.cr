require "../../src/gcry"
require "spec"

# A bitmap allocator's cursor claims a word's free blocks at once: their
# `occ` bits are set when the word is claimed, and each is handed out later
# by popping it from the cursor's mask (`Heap#cursor_claim_word`). The raw
# lookup, `find_object_with_chunk`, reads `occ` and so answers a claimed
# block as allocated — right for a pointer a program holds, which a claim
# never covers, wrong for one it kept after the block was freed. `GC_base`,
# `GC_size` and the finalizer registration used it, so the first allocation
# after a sweep in a freed block's class, on any thread, made every freed
# block of that word read live again with its old bytes intact. Regression
# 21 asks `GC_base` whether its eight control blocks survived three
# collections, and "controls kept 8 > 1" was that: all eight freed, all
# eight claimed by one 256-byte atomic allocation before the count
# (`bench/log/linux/2026-11-04-reg21-claimed-controls/FINDINGS.md`). Those
# lookups now leave a claimed block out (`Heap#find_live_object_with_chunk`).
#
# The regression makes eight 256-byte atomic blocks on a fiber that scrubs
# its frames, their addresses kept only masked in libc memory, collects
# three times, then allocates 256-byte atomic blocks with collection
# disabled until a freed block reads occupied and not live (`Heap#live?`,
# which subtracts the claim): claimed. The fixed arm must answer every
# claimed block free through `GC_base` and `GC_size`; the control arm
# (`Heap#live_lookup_exact = false`, the code before) must answer them live,
# or the fixed arm could pass on a heap where no claim covered a freed
# block. Each arm in a process of its own. Without a claim to test — no
# block freed, `GCRY_BITMAP_ALLOC=0`'s header allocator (no claims), or no
# claim reaching a freed block within the allocations — the child prints
# `CLAIM106_SKIP_MARK`.

private CLAIM106_SKIP_MARK = "claim106: no freed block claimed here, skipped"
private CLAIM106_LIVE      = "claim106: claimed blocks answered live"
private CLAIM106_FREE      = "claim106: claimed blocks answered free"

private CLAIM106_MASK   = 0x6A6A_6A6A_6A6A_6A6A_u64
private CLAIM106_BLOCKS =                         8
private CLAIM106_BYTES  =                       256
# Allocations made to reach a claim: four chunks' worth of 256-byte blocks
# at most.
private CLAIM106_TRIES = 4096

@[NoInline]
private def claim106_scrub_frames : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory" : "volatile")
end

# The blocks, made on a fiber of their own that scrubs its frames; their
# addresses only masked, in *masked*.
private def claim106_make(masked : UInt64*) : Nil
  done = Channel(Nil).new
  spawn do
    CLAIM106_BLOCKS.times do |i|
      p = GC.malloc_atomic(CLAIM106_BYTES)
      p.as(UInt8*).fill(CLAIM106_BYTES) { 0xA5_u8 }
      masked[i] = p.address ^ CLAIM106_MASK
      p = Pointer(Void).null
    end
    claim106_scrub_frames
    done.send(nil)
  end
  done.receive
  Fiber.yield
end

private def claim106_block(masked : UInt64*, i : Int32) : Void*
  Pointer(Void).new(masked[i] ^ CLAIM106_MASK)
end

# Occupied in `occ` and not handed out.
private def claim106_claimed?(heap : Gcry::Heap, p : Void*) : Bool
  !heap.find_object(p).nil? && !heap.live?(p)
end

private def claim106_child(arm : String) : Nil
  heap = Gcry.default_heap
  heap.live_lookup_exact = false if arm == "control"
  masked = LibC.malloc(LibC::SizeT.new(CLAIM106_BLOCKS * sizeof(UInt64))).as(UInt64*)
  claim106_make(masked)
  3.times { GC.collect }
  freed = (0...CLAIM106_BLOCKS).select { |i| heap.find_object(claim106_block(masked, i)).nil? }
  if freed.empty?
    STDERR.puts "#{CLAIM106_SKIP_MARK}: no block was freed"
    return
  end

  claimed = [] of Int32
  GC.disable
  begin
    CLAIM106_TRIES.times do
      GC.malloc_atomic(CLAIM106_BYTES)
      claimed = freed.select { |i| claim106_claimed?(heap, claim106_block(masked, i)) }
      break unless claimed.empty?
    end
    answered = claimed.count do |i|
      p = claim106_block(masked, i)
      LibGC.base(p) == p || LibGC.size(p) != 0
    end
  ensure
    GC.enable
  end
  if claimed.empty?
    STDERR.puts "#{CLAIM106_SKIP_MARK}: #{freed.size} freed, none claimed in #{CLAIM106_TRIES} allocations"
    return
  end
  STDERR.puts "claim106: #{arm}: #{freed.size} of #{CLAIM106_BLOCKS} freed, #{claimed.size} claimed, #{answered} answered live"
  STDERR.puts(answered == claimed.size ? CLAIM106_LIVE : (answered == 0 ? CLAIM106_FREE : "claim106: some answered live"))
end

describe "Regression: a block a cursor has claimed is not live to GC_base and GC_size" do
  {"fixed", "control"}.each do |arm|
    it "#{arm} arm in a process of its own" do
      captured = IO::Memory.new
      status = Process.run(Process.executable_path.not_nil!, ["-e", "claim106 child #{arm}"],
        env: {"GCRY_CLAIM106_CHILD" => arm}, output: captured, error: captured)
      text = captured.to_s
      text.each_line { |l| STDERR.puts "#{arm}: #{l}" if l.starts_with?("claim106:") }
      fail "#{arm} child #{status.inspect}:\n#{text}" unless status.success?
      text.should contain("1 examples, 0 failures")
      unless text.includes?(CLAIM106_SKIP_MARK)
        want = arm == "control" ? CLAIM106_LIVE : CLAIM106_FREE
        fail "#{arm} child: expected '#{want}':\n#{text}" unless text.includes?(want)
      end
    end
  end

  {"fixed", "control"}.each do |arm|
    it "claim106 child #{arm}" do
      next unless ENV["GCRY_CLAIM106_CHILD"]? == arm
      claim106_child(arm)
    end
  end
end
