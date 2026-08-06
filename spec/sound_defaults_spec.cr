require "./spec_helper"

# Root-completeness profile (docs/SOUND-DEFAULTS.md).
#
# These specs pin the *behaviour* each knob controls, not just the flag value:
# a profile that reports "sound" while still dropping roots would be worse
# than no profile at all.

private def sound_heap : Gcry::Heap
  heap = Gcry::Heap.new
  heap.gc_threshold = UInt64::MAX
  heap.layout_precise = false
  heap.allow_interior_pointers = true
  heap.scan_unaligned_candidates = true
  heap.type_id_gate = false
  heap.type_id_gate_stacks = false
  heap.stw_multi_stack_lag = 0_u64
  heap.stw_multi_pthread_lag = 0_u64
  heap.scrub_fibers_enabled = false
  heap.blacklist_enabled = false
  heap
end

it "reports tuned for a heap with root heuristics armed" do
  heap = Gcry::Heap.new
  begin
    heap.type_id_gate = true
    Gcry.sound_roots?(heap).should be_false
    Gcry.root_soundness(heap).should eq("tuned")
  ensure
    heap.destroy
  end
end

it "reports sound only when every root heuristic is off" do
  heap = sound_heap
  begin
    Gcry.sound_roots?(heap).should be_true
    Gcry.root_soundness(heap).should eq("sound")

    # Each knob alone is enough to lose the label.
    heap.type_id_gate = true
    Gcry.sound_roots?(heap).should be_false
    heap.type_id_gate = false

    heap.scrub_fibers_enabled = true
    Gcry.sound_roots?(heap).should be_false
    heap.scrub_fibers_enabled = false

    heap.stw_multi_stack_lag = 4096_u64
    Gcry.sound_roots?(heap).should be_false
    heap.stw_multi_stack_lag = 0_u64

    heap.allow_interior_pointers = false
    Gcry.sound_roots?(heap).should be_false
    heap.allow_interior_pointers = true

    heap.scan_unaligned_candidates = false
    Gcry.sound_roots?(heap).should be_false
    heap.scan_unaligned_candidates = true

    heap.precise_stack_exclusive = true
    Gcry.sound_roots?(heap).should be_false
    heap.precise_stack_exclusive = false

    Gcry.sound_roots?(heap).should be_true
  ensure
    heap.destroy
  end
end

# `str.to_unsafe + 3` is a legitimate live reference that bdwgc resolves via
# GC_base. The default alignment filter drops it before find_block ever runs.
it "drops a misaligned interior root when the alignment filter is armed" do
  heap = sound_heap
  begin
    heap.scan_unaligned_candidates = false

    target = heap.malloc(64)
    target.as(UInt8*).clear(64)

    root_words = heap.malloc(16)
    root_words.as(UInt8*).clear(16)
    # Only reference to `target` is 3 bytes into its payload.
    root_words.as(Void**).value = Pointer(Void).new(target.address + 3)

    heap.add_root(root_words)
    heap.before_collect do
      heap.push_stack(root_words, Pointer(Void).new(root_words.address + 16))
    end
    heap.collect(scan_stack: false)

    heap.live?(target).should be_false
  ensure
    heap.destroy
  end
end

it "follows a misaligned interior root under the sound profile" do
  heap = sound_heap
  begin
    target = heap.malloc(64)
    target.as(UInt8*).clear(64)

    root_words = heap.malloc(16)
    root_words.as(UInt8*).clear(16)
    root_words.as(Void**).value = Pointer(Void).new(target.address + 3)

    heap.add_root(root_words)
    heap.before_collect do
      heap.push_stack(root_words, Pointer(Void).new(root_words.address + 16))
    end
    heap.collect(scan_stack: false)

    heap.live?(target).should be_true
  ensure
    heap.destroy
  end
end

# scan_object marks raw-buffer bodies base-only, keyed off type_id_plausible?.
# That is a root-completeness heuristic on *heap edges* — an interior pointer
# stored inside a Slice / untyped allocation is dropped — and a second, silent
# consumer of the type_id heuristic. Both must follow allow_interior_pointers,
# or `root_soundness=sound` reports a collector that still loses objects.
it "drops an interior edge out of a raw buffer when interiors are off" do
  heap = sound_heap
  begin
    heap.allow_interior_pointers = false

    target = heap.malloc(64)
    target.as(UInt8*).clear(64)

    # Raw buffer: first Int32 is not a plausible Crystal type id.
    buf = heap.malloc(64)
    buf.as(UInt8*).clear(64)
    buf.as(UInt64*).value = 0x00007ffff0000000_u64
    # Sole reference to `target` is 8 bytes into its payload.
    Pointer(Void*).new(buf.address + 8).value = Pointer(Void).new(target.address + 8)

    heap.add_root(buf)
    heap.collect(scan_stack: false)

    heap.live?(buf).should be_true
    heap.live?(target).should be_false
  ensure
    heap.destroy
  end
end

it "follows an interior edge out of a raw buffer under the sound profile" do
  heap = sound_heap
  begin
    target = heap.malloc(64)
    target.as(UInt8*).clear(64)

    buf = heap.malloc(64)
    buf.as(UInt8*).clear(64)
    buf.as(UInt64*).value = 0x00007ffff0000000_u64
    Pointer(Void*).new(buf.address + 8).value = Pointer(Void).new(target.address + 8)

    heap.add_root(buf)
    heap.collect(scan_stack: false)

    heap.live?(target).should be_true
  ensure
    heap.destroy
  end
end

# A typed holder already kept interiors before the fix — pin it so the change
# is shown to be additive, not a swap of which case works.
it "follows an interior edge out of a typed object in both modes" do
  [true, false].each do |interiors|
    heap = sound_heap
    begin
      heap.allow_interior_pointers = interiors

      target = heap.malloc(64)
      target.as(UInt8*).clear(64)

      holder = heap.malloc(64)
      holder.as(UInt8*).clear(64)
      holder.as(Int32*).value = 7 # plausible type id
      Pointer(Void*).new(holder.address + 8).value = Pointer(Void).new(target.address + 8)

      heap.add_root(holder)
      heap.collect(scan_stack: false)

      heap.live?(target).should be_true
    ensure
      heap.destroy
    end
  end
end

# The type_id gate is the documented false-negative vector: a real reference
# whose first Int32 does not look like a Crystal type id is discarded.
it "keeps a gated-looking static root alive under the sound profile" do
  heap = sound_heap
  begin
    # Payload whose first Int32 is negative — rejected by type_id_plausible?.
    target = heap.malloc(32)
    target.as(UInt8*).clear(32)
    target.as(UInt64*).value = 0x0000555555555400_u64

    root_words = heap.malloc(16)
    root_words.as(UInt8*).clear(16)
    root_words.as(Void**).value = target

    heap.add_root(root_words)
    heap.before_collect do
      heap.push_stack(root_words, Pointer(Void).new(root_words.address + 16))
    end
    heap.collect(scan_stack: false)

    heap.live?(target).should be_true
    heap.type_id_root_rejects.should eq(0)
  ensure
    heap.destroy
  end
end

it "json_stats reports the live field values, not the requested profile" do
  heap = sound_heap
  begin
    json = Gcry::Observability.json_stats(heap)
    json.should contain(%("root_soundness":"sound"))
    json.should contain(%("allow_interior_pointers":true))
    json.should contain(%("scan_unaligned_candidates":true))
    json.should contain(%("type_id_gate":false))
    json.should contain(%("stw_multi_stack_lag":0))
    json.should contain(%("scrub_fibers_enabled":false))

    heap.type_id_gate = true
    Gcry::Observability.json_stats(heap).should contain(%("root_soundness":"tuned"))
  ensure
    heap.destroy
  end
end
