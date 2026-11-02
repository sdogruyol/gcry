require "../../src/gcry"
require "spec"

# A thread's pthread mapping is the stack of its main fiber, and the
# program's main fiber moves: the execution context's monitor hands the
# scheduler of a thread it catches inside `Fiber.syscall` to another thread,
# and the initial thread, once the call returns, parks in the thread pool on
# a loop fiber of its own. Its suspend SP is then off its mapping, and the
# stop-the-world scan read the mapping whole from its low-water mark
# (`Heap#scan_pthread_stack`) — the main fiber's stack, frames below the SP
# of whoever runs it included. A collection run on the main fiber has its
# own mark chain there, whose locals hold the chunk data start and block
# header of each candidate it looks up; those were taken for pointers, and
# regression 21's control blocks (its chunk's first block, and the block
# such a lookup had last named) were kept through all three of its
# collections whenever CI's 1.22.2 step ran with the main fiber moved.
# `bench/log/linux/2026-11-03-reg21-marked-unmarked/FINDINGS.md`. A thread
# running on the mapping now bounds that scan as the owner's own SP does
# (`Heap#pthread_scan_low_off_sp`).
#
# What the mark chain leaves there depends on the build and the heap, so
# the regression plants it: with the main fiber moved, a frame of 512 KiB
# writes the addresses of eight blocks over its deeper half and zeroes the
# rest, and returns; the blocks are made on another fiber that scrubs its
# frames, their addresses kept only masked in libc memory. The collector's
# frames, built under the plant's caller, stay in the zeroed half, so only a
# scan of the main stack below the collector's SP can read the plant. The
# fixed arm must free the blocks; the control arm
# (`Heap#pthread_scan_running_sp_clamp = false`, the code before) must keep
# them, or the fixed arm could pass on a heap where nothing reads the
# mapping; and so must an arm with no plant free them, or the control arm
# could be kept by something other than the plant. Each arm in a process of
# its own. Linux only (the move and the stack's growth under a frame that
# size are what it was built on), with the move made in at most ten
# 100 ms syscalls and the stop on its multi-mutator scan (which scans every
# pthread mapping); elsewhere, or without either, the child prints
# `PSTACK103_SKIP_MARK`.

private PSTACK103_SKIP_MARK = "pstack103: no moved main fiber on a multi-mutator stop here, skipped"
private PSTACK103_KEPT      = "pstack103: planted blocks kept"
private PSTACK103_FREED     = "pstack103: planted blocks freed"

private PSTACK103_MASK   = 0x3C3C_3C3C_3C3C_3C3C_u64
private PSTACK103_BLOCKS =                         8
private PSTACK103_WORDS  =                     65536

class Gcry::Heap
  def pstack103_multi_mutator? : Bool
    multi_mutator_threads?
  end
end

@[NoInline]
private def pstack103_scrub_frames : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory" : "volatile")
end

# The blocks, made on a fiber of their own that scrubs its frames; their
# addresses only masked, in *masked*.
private def pstack103_make(masked : UInt64*) : Nil
  done = Channel(Nil).new
  spawn do
    PSTACK103_BLOCKS.times do |i|
      p = GC.malloc_atomic(256)
      masked[i] = p.address ^ PSTACK103_MASK
      p = Pointer(Void).null
    end
    pstack103_scrub_frames
    done.send(nil)
  end
  done.receive
  Fiber.yield
end

# 512 KiB of frame: the deeper (lower) half holds the blocks' addresses,
# the half under the caller zeros.
@[NoInline]
private def pstack103_plant(masked : UInt64*, plant : Bool) : Nil
  buf = uninitialized StaticArray(UInt64, PSTACK103_WORDS)
  words = buf.to_unsafe
  half = PSTACK103_WORDS // 2
  PSTACK103_WORDS.times do |i|
    words[i] = plant && i < half ? masked[i % PSTACK103_BLOCKS] ^ PSTACK103_MASK : 0_u64
  end
  asm("" :: "r"(words) : "memory" : "volatile")
end

private def pstack103_kept(heap : Gcry::Heap, masked : UInt64*) : Int32
  PSTACK103_BLOCKS.times.count { |i| !heap.find_object(Pointer(Void).new(masked[i] ^ PSTACK103_MASK)).nil? }
end

private def pstack103_child(arm : String) : Nil
  {% if flag?(:linux) %}
    heap = Gcry.default_heap
    heap.pthread_scan_running_sp_clamp = false unless arm == "fixed"
    initial = Gcry::Platform.current_thread_id
    ts = LibC::Timespec.new(tv_sec: 0, tv_nsec: 100_000_000)
    10.times do
      break unless Gcry::Platform.current_thread_id == initial
      Fiber.syscall { LibC.nanosleep(pointerof(ts), nil) }
    end
    if Gcry::Platform.current_thread_id == initial
      STDERR.puts "#{PSTACK103_SKIP_MARK}: the main fiber stayed on the initial thread"
      return
    end
    unless heap.pstack103_multi_mutator?
      STDERR.puts "#{PSTACK103_SKIP_MARK}: the stop takes the single-mutator scan"
      return
    end
    masked = LibC.malloc(LibC::SizeT.new(PSTACK103_BLOCKS * sizeof(UInt64))).as(UInt64*)
    pstack103_make(masked)
    pstack103_plant(masked, arm != "unplanted")
    3.times { GC.collect }
    kept = pstack103_kept(heap, masked)
    STDERR.puts "pstack103: #{arm}: #{kept} of #{PSTACK103_BLOCKS} planted blocks kept"
    STDERR.puts(kept >= PSTACK103_BLOCKS - 1 ? PSTACK103_KEPT : (kept <= 1 ? PSTACK103_FREED : "pstack103: some kept"))
  {% else %}
    STDERR.puts PSTACK103_SKIP_MARK
  {% end %}
end

describe "Regression: a pthread mapping another thread runs on is scanned from that thread's SP" do
  {"fixed", "control", "unplanted"}.each do |arm|
    it "#{arm} arm in a process of its own" do
      captured = IO::Memory.new
      status = Process.run(Process.executable_path.not_nil!, ["-e", "pstack103 child #{arm}"],
        env: {"GCRY_PSTACK103_CHILD" => arm}, output: captured, error: captured)
      text = captured.to_s
      text.each_line { |l| STDERR.puts "#{arm}: #{l}" if l.starts_with?("pstack103:") }
      fail "#{arm} child #{status.inspect}:\n#{text}" unless status.success?
      text.should contain("1 examples, 0 failures")
      unless text.includes?(PSTACK103_SKIP_MARK)
        want = arm == "control" ? PSTACK103_KEPT : PSTACK103_FREED
        fail "#{arm} child: expected '#{want}':\n#{text}" unless text.includes?(want)
      end
    end
  end

  {"fixed", "control", "unplanted"}.each do |arm|
    it "pstack103 child #{arm}" do
      next unless ENV["GCRY_PSTACK103_CHILD"]? == arm
      pstack103_child(arm)
    end
  end
end
