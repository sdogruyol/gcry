require "../../src/gcry"
require "spec"

# Three places the root scan read words nothing had written in the frame
# being scanned, each a residue of earlier calls at the same depth. Two were
# found holding `make parallel-dormant`'s dropped burst, a 3.6 MiB
# outer-array buffer and the 36 MB it names, through every collection
# (`bench/log/linux/2026-11-03-parked-seed/FINDINGS.md`).
#
# **The idle thread's loop frame.** The idle collector's thread never
# returns from `IdleRelease.loop_forever`, and the scan reads that frame at
# every collection for the life of the process. A slot of it the function
# never writes keeps whatever the thread's birth left at that depth
# (`Thread#start` allocates the main `Fiber` there just before): in CI (job
# 125102880486) and 0.3–0.5% of local runs, "seeded by … parked 3713 KiB".
# The thread now zeroes its stack below the block that starts it before the
# loop's frame is built there. What a birth leaves depends on the build and
# the heap, so the regression plants it: the thread writes a block's address
# over 64 KiB of its stack under that block before anything else
# (`IdleRelease.test_birth_plant`). The block is made on a fiber that scrubs
# its frames, its address kept masked in libc memory and, until the thread
# has parked, in a static slot that is then cleared. The idle thread is
# armed only after that, so the collection that ends by starting it keeps
# the block and the thread plants a live block's address. Once the thread is
# parked and the slot cleared, three collections. The fixed arm must free
# the block; the control arm (`IdleRelease.birth_residue_kept`, the code
# before) must keep it, or the fixed arm could pass on a build where the
# loop frame writes every slot; and an arm with no plant must free it, or
# the control arm could be kept by something other than the plant. Each arm
# starts with the idle thread off (`GCRY_IDLE_RELEASE_MS=0`).
#
# **The mutator scan's own frames.** The collecting thread's stack is read
# from the scan's own SP, so the frames of `scan_mutator_stack` are read
# too, and a slot of them not written before it is read keeps what this
# cycle's earlier phases left at that depth: "seeded by stack 3715 KiB",
# 0.1–0.4% of local runs. The collector now scrubs below its frame once
# more just before that scan (`Heap#pre_mutator_scan_scrub`). The regression
# plants from the collection's `MarkStart` event, which the collector raises
# from the frame that later calls the scan: a hook fills 16 KiB below it
# with a block's address, made and held as above, the static slot cleared
# before the three collections. Fixed frees it; control
# (`Heap#mutator_scan_scrub = false`) keeps it; unplanted frees it.
#
# **The register buffer.** `Roots.capture_registers` hands every caller a
# 256-byte buffer to scan whole, and `setjmp` writes 80 bytes of it on
# x86_64 glibc; the other 21 words were read as registers. It is cleared
# before the capture now. The regression dirties 16 KiB of stack with a
# pattern from a frame that returns, then captures from a frame built over
# it (`Roots.each_spilled_register`, which yields the buffer alone): the
# fixed arm must yield no pattern word, the control arm
# (`Roots.register_residue_kept`, the code before) at least one, or the
# fixed arm could pass on a layout where the buffer lies outside the dirtied
# range.
#
# Each arm in a process of its own. Linux only, where all three were found
# and measured; elsewhere the child prints `UNWRITTEN104_SKIP_MARK` (and
# Windows cleared its register buffer already). The idle arms also skip
# under `-Dwithout_mt`, where there is no idle thread.

private UNWRITTEN104_SKIP_MARK = "unwritten104: not on this platform, skipped"
private IDLE104_KEPT           = "unwritten104: idle: planted block kept"
private IDLE104_FREED          = "unwritten104: idle: planted block freed"
private REG104_SEEN            = "unwritten104: registers: pattern yielded"
private REG104_CLEAN           = "unwritten104: registers: pattern not yielded"
private SCAN104_KEPT           = "unwritten104: mutator scan: planted block kept"
private SCAN104_FREED          = "unwritten104: mutator scan: planted block freed"

# A size of its own, so nothing the child allocates afterwards takes the
# freed block's address before it is looked up.
private IDLE104_BYTES = 20_000

# The pattern the register arms dirty the stack with, stored masked.
private REG104_MASK    = 0x3939_c6c6_3939_c6c6_u64
private REG104_PATTERN = 0x0104_5eed_0104_5eed_u64
private REG104_WORDS   =                      2048

# The block's one reference until the idle thread has parked: static data,
# a root no stack scan involves.
private module Idle104Hold
  class_property block : Void* = Pointer(Void).null
end

@[NoInline]
private def idle104_scrub_frames : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory" : "volatile")
end

# The block, made on a fiber of its own that scrubs its frames; its address
# masked with the plant's key in *masked*, and held in `Idle104Hold`.
private def idle104_make(masked : UInt64*) : Nil
  done = Channel(Nil).new
  spawn do
    p = GC.malloc_atomic(IDLE104_BYTES)
    masked.value = p.address ^ Gcry::IdleRelease::BIRTH_PLANT_KEY
    Idle104Hold.block = p
    p = Pointer(Void).null
    idle104_scrub_frames
    done.send(nil)
  end
  done.receive
  Fiber.yield
end

private def idle104_child(arm : String) : Nil
  {% if flag?(:linux) && !flag?(:without_mt) %}
    heap = Gcry.default_heap
    Gcry::IdleRelease.armed?.should be_false
    Gcry::IdleRelease.birth_residue_kept = arm == "control"
    masked = LibC.malloc(LibC::SizeT.new(sizeof(UInt64))).as(UInt64*)
    idle104_make(masked)
    Gcry::IdleRelease.test_birth_plant = masked.value unless arm == "unplanted"
    # Long enough that the thread only polls: no idle collection of its own.
    Gcry::IdleRelease.idle_ms = 600_000_u64
    GC.collect
    deadline = Time.instant + 10.seconds
    while Gcry::IdleRelease.parked_sp == 0
      fail "the idle thread did not park" if Time.instant > deadline
      sleep 1.millisecond
    end
    Idle104Hold.block = Pointer(Void).null
    3.times { GC.collect }
    kept = !heap.find_object(Pointer(Void).new(masked.value ^ Gcry::IdleRelease::BIRTH_PLANT_KEY)).nil?
    STDERR.puts "unwritten104: idle #{arm}: block #{kept ? "kept" : "freed"} after three collections with the idle thread parked"
    STDERR.puts(kept ? IDLE104_KEPT : IDLE104_FREED)
  {% else %}
    STDERR.puts UNWRITTEN104_SKIP_MARK
  {% end %}
end

# The masked address the `MarkStart` hook plants, 0 for none.
private module Scan104Plant
  class_property masked : UInt64 = 0_u64
end

# 16 KiB below the collector's frame filled with the block's address.
@[NoInline]
private def scan104_plant : Nil
  pad = uninitialized StaticArray(UInt64, REG104_WORDS)
  word = Scan104Plant.masked ^ Gcry::IdleRelease::BIRTH_PLANT_KEY
  REG104_WORDS.times { |i| pad[i] = word }
  asm("" :: "r"(pad.to_unsafe) : "memory" : "volatile")
end

private def scan104_child(arm : String) : Nil
  {% if flag?(:linux) %}
    heap = Gcry.default_heap
    heap.mutator_scan_scrub = arm != "control"
    masked = LibC.malloc(LibC::SizeT.new(sizeof(UInt64))).as(UInt64*)
    idle104_make(masked)
    Scan104Plant.masked = masked.value unless arm == "unplanted"
    heap.collection_event_hook = ->(event : Gcry::Heap::CollectionEvent) do
      scan104_plant if event.mark_start? && Scan104Plant.masked != 0
      nil
    end
    Idle104Hold.block = Pointer(Void).null
    3.times { GC.collect }
    heap.collection_event_hook = nil
    kept = !heap.find_object(Pointer(Void).new(masked.value ^ Gcry::IdleRelease::BIRTH_PLANT_KEY)).nil?
    STDERR.puts "unwritten104: mutator scan #{arm}: block #{kept ? "kept" : "freed"} after three collections"
    STDERR.puts(kept ? SCAN104_KEPT : SCAN104_FREED)
  {% else %}
    STDERR.puts UNWRITTEN104_SKIP_MARK
  {% end %}
end

# 16 KiB of frame filled with the pattern, then returned from.
@[NoInline]
private def reg104_dirty : Nil
  pad = uninitialized StaticArray(UInt64, REG104_WORDS)
  word = REG104_PATTERN
  REG104_WORDS.times { |i| pad[i] = word }
  asm("" :: "r"(pad.to_unsafe) : "memory" : "volatile")
end

# The capture, from a frame built where `reg104_dirty`'s was. The pattern is
# compared masked so this frame holds no copy of it.
@[NoInline]
private def reg104_probe : Int32
  hits = 0
  Gcry::Roots.each_spilled_register do |candidate|
    hits += 1 if (candidate.address ^ REG104_MASK) == (REG104_PATTERN ^ REG104_MASK)
  end
  hits
end

private def reg104_child(arm : String) : Nil
  {% if flag?(:linux) %}
    Gcry::Roots.register_residue_kept = arm == "control"
    reg104_dirty
    hits = reg104_probe
    STDERR.puts "unwritten104: registers #{arm}: #{hits} pattern word(s) yielded from the register buffer"
    STDERR.puts(hits > 0 ? REG104_SEEN : REG104_CLEAN)
  {% else %}
    STDERR.puts UNWRITTEN104_SKIP_MARK
  {% end %}
end

private def unwritten104_run(child : String, arm : String, want : String, env = {} of String => String) : Nil
  captured = IO::Memory.new
  status = Process.run(Process.executable_path.not_nil!, ["-e", "unwritten104 child #{child} #{arm}"],
    env: {"GCRY_UNWRITTEN104_CHILD" => "#{child} #{arm}"}.merge(env), output: captured, error: captured)
  text = captured.to_s
  text.each_line { |l| STDERR.puts "#{child} #{arm}: #{l}" if l.starts_with?("unwritten104:") }
  fail "#{child} #{arm} child #{status.inspect}:\n#{text}" unless status.success?
  text.should contain("1 examples, 0 failures")
  unless text.includes?(UNWRITTEN104_SKIP_MARK)
    fail "#{child} #{arm} child: expected '#{want}':\n#{text}" unless text.includes?(want)
  end
end

describe "Regression: the root scan reads no word nothing wrote" do
  {"fixed", "control", "unplanted"}.each do |arm|
    it "idle thread's loop frame, #{arm} arm in a process of its own" do
      unwritten104_run("idle", arm, arm == "control" ? IDLE104_KEPT : IDLE104_FREED, {"GCRY_IDLE_RELEASE_MS" => "0"})
    end
  end

  {"fixed", "control"}.each do |arm|
    it "register buffer, #{arm} arm in a process of its own" do
      unwritten104_run("registers", arm, arm == "control" ? REG104_SEEN : REG104_CLEAN)
    end
  end

  {"fixed", "control", "unplanted"}.each do |arm|
    it "mutator scan's own frames, #{arm} arm in a process of its own" do
      unwritten104_run("scan", arm, arm == "control" ? SCAN104_KEPT : SCAN104_FREED)
    end
  end

  {"fixed", "control", "unplanted"}.each do |arm|
    it "unwritten104 child idle #{arm}" do
      next unless ENV["GCRY_UNWRITTEN104_CHILD"]? == "idle #{arm}"
      idle104_child(arm)
    end
  end

  {"fixed", "control"}.each do |arm|
    it "unwritten104 child registers #{arm}" do
      next unless ENV["GCRY_UNWRITTEN104_CHILD"]? == "registers #{arm}"
      reg104_child(arm)
    end
  end

  {"fixed", "control", "unplanted"}.each do |arm|
    it "unwritten104 child scan #{arm}" do
      next unless ENV["GCRY_UNWRITTEN104_CHILD"]? == "scan #{arm}"
      scan104_child(arm)
    end
  end
end
