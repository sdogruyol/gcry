require "../../src/gcry"
require "spec"

# A thread allocates through a cursor set of its own, one of a table of
# `Heap::MAX_CURSOR_SETS`; a thread that finds the table full shares the
# fallback set, and keeps it for the rest of its life. The fallback never
# takes the hit path, and every stop pinned its chunks (as it did the
# monitor's and the out-of-memory reserve's), so the after-world sweep never
# swept a chunk it held: every block that died there stayed allocated until
# the cursor moved on. Regression 21's "controls kept 8 > 1" on Crystal 1.22.2
# headerless (1 in 174 suite-order runs) is that: with the main fiber moved
# right after `process_gc_spec`'s 80 threads fill the table, the pool thread
# that takes it is on the fallback, its eight dead controls sit in the
# fallback's chunk, and `GC_base` answers them live after three collections,
# every run (`bench/log/linux/2026-11-07-reg21-fallback-pinned/FINDINGS.md`).
# The stop now pins such a set only when it is mid-allocation
# (`Heap#bitmap_settle_cursor_sets`).
#
# The regression parks `MAX_CURSOR_SETS` threads, each after one allocation,
# so the table is full; one more thread makes eight 256-byte atomic blocks
# through the fallback, keeps their addresses only masked in libc memory,
# scrubs its frames and exits. Three collections from the main thread must
# free them (at most one kept, for a stale word) in the fixed arm and keep
# all eight in the control arm (`Heap#no_hit_sets_swept = false`, the code
# before). Each arm in a process of its own. Without the blocks on a chunk the
# fallback holds — `GCRY_BITMAP_ALLOC=0`'s header allocator has no cursor
# sets — or, in the control arm, without an after-world sweep that met the
# pinned chunk, the child prints `NOHIT109_SKIP_MARK`.

private NOHIT109_SKIP_MARK = "nohit109: blocks not where the regression needs them, skipped"
private NOHIT109_FREED     = "nohit109: blocks freed"
private NOHIT109_KEPT      = "nohit109: blocks kept"

private NOHIT109_MASK   = 0x6D6D_6D6D_6D6D_6D6D_u64
private NOHIT109_BLOCKS =                         8
private NOHIT109_BYTES  =                       256

private def nohit109_nap : Nil
  {% if flag?(:win32) %}
    LibC.Sleep(1)
  {% else %}
    req = LibC::Timespec.new(tv_sec: 0, tv_nsec: 1_000_000)
    LibC.nanosleep(pointerof(req), Pointer(LibC::Timespec).null)
  {% end %}
end

@[NoInline]
private def nohit109_scrub_frames : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory" : "volatile")
end

@[NoInline]
private def nohit109_make(masked : UInt64*) : Nil
  NOHIT109_BLOCKS.times do |i|
    p = GC.malloc_atomic(NOHIT109_BYTES)
    p.as(UInt8*).fill(NOHIT109_BYTES) { 0x5A_u8 }
    masked[i] = p.address ^ NOHIT109_MASK
    p = Pointer(Void).null
  end
end

private def nohit109_block(masked : UInt64*, i : Int32) : Void*
  Pointer(Void).new(masked[i] ^ NOHIT109_MASK)
end

# Is the chunk of *p* in one of the fallback set's slots?
private def nohit109_on_fallback?(heap : Gcry::Heap, p : Void*) : Bool
  fallback = heap.@fallback_cursor_set
  return false if fallback.null?
  found = heap.find_object_with_chunk(p)
  return false unless found
  chunk = found[1]
  (0...Gcry::POOL_SLOTS).any? { |i| Gcry::CursorSet.slot(fallback, i).value.chunk == chunk }
end

private def nohit109_child(arm : String) : Nil
  heap = Gcry.default_heap
  heap.no_hit_sets_swept = false if arm == "control"
  stop = Atomic(Int32).new(0)
  ready = Atomic(Int32).new(0)
  parkers = Array(Thread).new(Gcry::Heap::MAX_CURSOR_SETS) do
    Thread.new do
      GC.malloc_atomic(16)
      ready.add(1)
      until stop.get == 1
        nohit109_nap
      end
    end
  end
  begin
    until ready.get == parkers.size
      nohit109_nap
    end
    masked = LibC.malloc(LibC::SizeT.new(NOHIT109_BLOCKS * sizeof(UInt64))).as(UInt64*)
    Thread.new do
      nohit109_make(masked)
      nohit109_scrub_frames
    end.join
    unless nohit109_on_fallback?(heap, nohit109_block(masked, 0))
      STDERR.puts "#{NOHIT109_SKIP_MARK}: not on the fallback set's chunk (#{heap.cursor_set_count} sets)"
      return
    end
    pinned_before = heap.sweep_cursor_pinned
    3.times { GC.collect }
    pinned = heap.sweep_cursor_pinned &- pinned_before
    kept = (0...NOHIT109_BLOCKS).count do |i|
      p = nohit109_block(masked, i)
      heap.live?(p) || LibGC.base(p) == p
    end
    if arm == "control" && pinned == 0
      STDERR.puts "#{NOHIT109_SKIP_MARK}: no after-world sweep met a pinned chunk"
      return
    end
    STDERR.puts "nohit109: #{arm}: #{kept} of #{NOHIT109_BLOCKS} kept after three collections, #{pinned} pinned chunk(s) skipped by the sweep"
    STDERR.puts(kept <= 1 ? NOHIT109_FREED : (kept == NOHIT109_BLOCKS ? NOHIT109_KEPT : "nohit109: some kept"))
  ensure
    stop.set(1)
    parkers.each(&.join)
  end
end

describe "Regression: the chunks of a cursor set that never takes the hit path are swept" do
  {"fixed", "control"}.each do |arm|
    it "#{arm} arm in a process of its own" do
      captured = IO::Memory.new
      status = Process.run(Process.executable_path.not_nil!, ["-e", "nohit109 child #{arm}"],
        env: {"GCRY_NOHIT109_CHILD" => arm}, output: captured, error: captured)
      text = captured.to_s
      text.each_line { |l| STDERR.puts "#{arm}: #{l}" if l.starts_with?("nohit109:") }
      fail "#{arm} child #{status.inspect}:\n#{text}" unless status.success?
      text.should contain("1 examples, 0 failures")
      unless text.includes?(NOHIT109_SKIP_MARK)
        want = arm == "control" ? NOHIT109_KEPT : NOHIT109_FREED
        fail "#{arm} child: expected '#{want}':\n#{text}" unless text.includes?(want)
      end
    end
  end

  {"fixed", "control"}.each do |arm|
    it "nohit109 child #{arm}" do
      next unless ENV["GCRY_NOHIT109_CHILD"]? == arm
      nohit109_child(arm)
    end
  end
end
