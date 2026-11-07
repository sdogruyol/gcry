require "../../src/gcry"
require "spec"

# On macOS the kernel put the heap right after the executable, at 4–8 GiB,
# where 33-bit integers point. On the M1 a `5 000 000 000` (`0x12a05f200`)
# beside a code pointer in a system library's `__DATA`, scanned as a static
# root, kept a dead 32 or 128 MiB `IO::Memory` buffer of JsonGenerate's
# (`bench/log/macos/2026-10-23-jsongen-m1/`). Every heap mapping on macOS is
# now asked for at a random base 16 to 32 TiB up (`Gcry.high_heap_base`), out
# of reach of any integer below 2^44.
#
# The construction. `Gcry.map_hint` stands for the kernel's answer: a heap
# mapping that follows it lands where the old placement could put one, here
# over the constant. Both arms ask for a 32 MiB block with that hint and a
# class variable holding the constant (static data, a root as the library's
# was); then the block is dropped and the heap collected.
#
# - control (`GCRY_HIGH_HEAP=0`, the placement before): the block covers the
#   constant, the word names it, and the collection keeps it.
# - fixed (the default): every chunk of the heap, its first mapping and the
#   block included, lies at or above the base, the base at or above 2^44,
#   and the constant names nothing before or after the collection.
#
# Each arm runs in a process of its own: the placement is chosen at the first
# heap mapping and the control's heap must be the kernel's from the start.
# The control skips, with `C92_SKIP_MARK`, where something else already holds
# the constant's address space. Other platforms keep the kernel's placement
# (Linux and Windows put the heap far above 2^40 already), so the examples
# are pending there.

private C92_SKIP_MARK = "high92: the constant's address space is taken, control skipped"
private C92_CONSTANT  = 5_000_000_000_u64
private C92_BLOCK     = 32_u64 << 20

# The constant as a word in static data, as the system library had it.
class C92Static
  @@word = 5_000_000_000_u64

  def self.word : UInt64
    @@word
  end
end

{% if flag?(:darwin) %}
  # The large chunk holding *user*, as `{base, mapped bytes}`.
  private def c92_large_span(heap : Gcry::Heap, user : Void*) : {UInt64, UInt64}
    span = {0_u64, 0_u64}
    heap.each_chunk do |chunk|
      next unless Gcry::ChunkHeader.large?(chunk)
      next unless Gcry::ChunkHeader.large_user(chunk) == user
      span = {chunk.address, chunk.value.mapped_bytes}
    end
    span
  end

  # The lowest chunk of *heap*.
  private def c92_lowest_chunk(heap : Gcry::Heap) : UInt64
    low = UInt64::MAX
    heap.each_chunk { |chunk| low = chunk.address if chunk.address < low }
    low
  end

  # The 1 MiB-aligned address a block mapped there covers the constant from,
  # 1.4 MiB into its data; off every 4 GiB window.
  private def c92_hint : UInt64
    (C92_CONSTANT &- (1_u64 << 20)) & ~((1_u64 << 20) &- 1)
  end

  # Whether the block's whole mapping is free at the hint: asked for there
  # and given back.
  private def c92_hint_free? : Bool
    len = LibC::SizeT.new(C92_BLOCK &+ (1_u64 << 20))
    at = Gcry::OS.mmap(Pointer(Void).new(c92_hint), len, Gcry::OS::PROT_NONE,
      Gcry::OS::MAP_PRIVATE | Gcry::OS::MAP_ANONYMOUS, -1, 0)
    return false if Gcry.mmap_failed?(at)
    Gcry::OS.munmap(at, len)
    at.address == c92_hint
  end

  # Allocates the block with the hint as the kernel's answer and returns
  # `{chunk base, mapped bytes}`, dropping the pointer in this frame.
  @[NoInline]
  private def c92_block(heap : Gcry::Heap) : {UInt64, UInt64}
    Gcry.map_hint = c92_hint
    user = begin
      GC.malloc_atomic(LibC::SizeT.new(C92_BLOCK))
    ensure
      Gcry.map_hint = 0_u64
    end
    user.null?.should be_false
    c92_large_span(heap, user)
  end

  private def c92_child(arm : String) : Nil
    heap = Gcry.default_heap
    word = Pointer(Void).new(C92Static.word)
    if arm == "fixed"
      Gcry.high_heap?.should be_true
      base = Gcry.high_heap_base
      (base >= Gcry::HIGH_HEAP_FLOOR).should be_true
      (base < Gcry::HIGH_HEAP_FLOOR &* 2).should be_true
      # Everything mapped so far, the heap's first mapping included.
      c92_lowest_chunk(heap).should be >= base
    else
      Gcry.high_heap?.should be_false
      unless c92_hint_free?
        STDOUT.puts C92_SKIP_MARK
        STDOUT.flush
        return
      end
    end
    misses = arm == "fixed" ? Gcry.high_heap_misses : 0_u64
    at, len = c92_block(heap)
    len.should be >= C92_BLOCK
    covers = at <= word.address && word.address < at &+ len
    named = !heap.find_block(word).nil?
    GC.collect
    GC.collect
    kept = heap.live?(word)
    if arm == "fixed"
      (at >= Gcry.high_heap_base).should be_true
      covers.should be_false
      named.should be_false
      kept.should be_false
      Gcry.high_heap_misses.should eq(misses)
      c92_lowest_chunk(heap).should be >= Gcry.high_heap_base
      STDOUT.puts "high92: fixed: heap at or above 0x#{Gcry.high_heap_base.to_s(16)}, block at 0x#{at.to_s(16)}, the constant names nothing"
    else
      # The hint put the block over the constant, and the word kept it.
      covers.should be_true
      named.should be_true
      kept.should be_true
      STDOUT.puts "high92: control: block at 0x#{at.to_s(16)} covers 0x#{word.address.to_s(16)} and the collection kept it"
    end
    STDOUT.flush
  end
{% end %}

describe "Regression: on macOS no heap mapping lies where a 33-bit integer points" do
  {"fixed", "control"}.each do |arm|
    it "#{arm} arm in a process of its own" do
      pending! "the high placement is macOS's" unless {{ flag?(:darwin) }}
      captured = IO::Memory.new
      env = {"GCRY_HIGH92_CHILD" => arm} of String => String?
      env["GCRY_HIGH_HEAP"] = "0" if arm == "control"
      status = Process.run(Process.executable_path.not_nil!, ["-e", "high92 child #{arm}"],
        env: env, output: captured, error: captured)
      fail "child #{status.inspect}:\n#{captured}" unless status.success?
      out = captured.to_s
      if arm == "control"
        next if out.includes?(C92_SKIP_MARK)
        out.should contain("high92: control: block at")
      else
        out.should contain("high92: fixed: heap at or above")
      end
      out.should contain("1 examples, 0 failures")
    end
  end

  {"fixed", "control"}.each do |arm|
    it "high92 child #{arm}" do
      next unless ENV["GCRY_HIGH92_CHILD"]? == arm
      {% if flag?(:darwin) %}
        c92_child(arm)
      {% end %}
    end
  end
end
