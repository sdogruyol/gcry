require "../../src/gcry"
require "spec"
require "weak_ref"

# The collector's entry scrub (`Heap#collect_scrub`) zeroes 16 KiB below its
# own SP but leaves the 192 bytes just under it as they were (red zone plus
# leaf margin: its `memset` runs there). The collector's frames are built
# over that band and the stack scan reads it. The allocation slow path
# (`cursor_claim_word`) left a chunk's data start in it, the header address
# of the chunk's first block, which gcry accepts as a pointer into that
# block: regression 61's target, when it was its chunk's first block, was
# kept through three `GC.collect`s (4 of 20 suite-order runs on 551acbfc,
# `bench/log/linux/2026-11-02-reg61-flake/`). `run_collection` now wipes the
# band from its own frame after each scrub (`Heap#collect_band_wipe`).
#
# Which word the slow path leaves there depends on the build and the
# allocation history, so the regression plants it: with `scrub_band_plant`
# set, each collector scrub writes the target's address over the whole band
# it skipped once its `memset` is done. The target is made on another fiber,
# which sets the plant (stored masked) and scrubs its own frames, so nothing
# else holds it. Each arm in a process of its own, any build or layout,
# x86-64 and arm64 outside Windows (Windows' scrub, `OS.clear_dead_stack`,
# zeroes up to its SP and leaves no band; the wipe runs there too). The
# control arm (`GCRY_COLLECT_BAND_WIPE=0`) must keep the target, or the fixed
# arm could pass on a layout where the collector's frames overwrite the band
# anyway; the fixed arm must free it, and so must an arm with no plant
# (`GCRY_SCRUB101_PLANT=0`), or the control arm could be kept by something
# other than the band.
private SCRUB101_SKIP_MARK = "scrub101: no band on this target (Windows, or no wipe_below_sp), skipped"
private SCRUB101_KEPT      = "scrub101: target kept"
private SCRUB101_FREED     = "scrub101: target freed"

private class Scrub101Target
  @pad = StaticArray(UInt64, 6).new(0_u64)
end

# Zeroes the dead stack below the caller, so the fiber that made the target
# leaves no word of it behind.
@[NoInline]
private def scrub101_scrub_frames : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory" : "volatile")
end

# The target and the plant, in a frame of their own below the fiber's entry,
# which the scrub after it then zeroes: in a `--release` build a target made
# in the spawned block itself was kept with no plant at all, and the
# address-space audit found it in that fiber's top frame, 176 bytes below its
# stack top, above anything the scrub reaches.
@[NoInline]
private def scrub101_make(heap : Gcry::Heap, plant : Bool) : WeakRef(Scrub101Target)
  t = Scrub101Target.new
  heap.scrub_band_plant = t.as(Void*).address ^ Gcry::Heap::SCRUB_BAND_PLANT_MASK if plant
  WeakRef.new(t)
end

private def scrub101_child : Nil
  heap = Gcry.default_heap
  ref = nil
  plant = ENV["GCRY_SCRUB101_PLANT"]? != "0"
  # Made on another fiber, which also sets the plant and scrubs its frames:
  # no live word anywhere but the band holds the target, this frame's
  # included.
  done = Channel(Nil).new
  spawn do
    ref = scrub101_make(heap, plant)
    scrub101_scrub_frames
    done.send(nil)
  end
  done.receive
  Fiber.yield
  begin
    3.times { GC.collect }
  ensure
    heap.scrub_band_plant = 0_u64
  end
  depth = heap.collect_entry_sp.to_i64 - heap.scrub_band_low.to_i64
  STDERR.puts "scrub101: wipe #{heap.collect_band_wipe}, band #{heap.scrub_band_high - heap.scrub_band_low} bytes, its low end #{depth} bytes below the entry SP"
  STDERR.puts(ref.not_nil!.value.nil? ? SCRUB101_FREED : SCRUB101_KEPT)
end

describe "Regression: the band under the collector scrub's own call is wiped" do
  it "frees a block only a word in that band points at" do
    {% if (flag?(:x86_64) || flag?(:aarch64)) && !flag?(:win32) %}
      {"fixed", "control", "unplanted"}.each do |arm|
        captured = IO::Memory.new
        env = {"GCRY_SCRUB101_CHILD" => "1"}
        env["GCRY_COLLECT_BAND_WIPE"] = "0" if arm == "control"
        env["GCRY_SCRUB101_PLANT"] = "0" if arm == "unplanted"
        status = Process.run(Process.executable_path.not_nil!, ["-e", "scrub-band child"],
          env: env, output: captured, error: captured)
        text = captured.to_s
        text.each_line { |l| STDERR.puts "#{arm}: #{l}" if l.starts_with?("scrub101:") }
        fail "#{arm} child #{status.inspect}:\n#{text}" unless status.success?
        want = arm == "control" ? SCRUB101_KEPT : SCRUB101_FREED
        fail "#{arm} child: expected '#{want}':\n#{text}" unless text.includes?(want)
      end
    {% else %}
      STDERR.puts SCRUB101_SKIP_MARK
    {% end %}
  end

  it "scrub-band child" do
    next unless ENV["GCRY_SCRUB101_CHILD"]? == "1"
    scrub101_child
  end
end
