require "./spec_helper"

# Inject the other lock domain's update after a setter has loaded its input.
# The former whole-header copy wrote that concurrent update back to its old
# value. These hooks exist only in the spec binary.
module ChunkFieldRaceSpec
  class_property before_flags : Proc(Nil)?
  class_property before_next : Proc(Nil)?
end

struct Gcry::ChunkHeader
  # With a copied struct, intercept the property setter between snapshot and
  # copyback. With the field-specific operations there is no such window:
  # schedule the peer update immediately after the indivisible field store.
  # Keeping both hooks makes this test fail if whole-header writes return.
  def flags=(value : UInt32)
    run_flags_peer_for_spec
    previous_def
  end

  def next=(value : ChunkHeader*)
    run_next_peer_for_spec
    previous_def
  end

  private def self.update_flag(chunk : ChunkHeader*, flag : UInt32, value : Bool) : Nil
    previous_def
    run_flags_peer_for_spec
  end

  def self.set_next(chunk : ChunkHeader*, successor : ChunkHeader*) : Nil
    previous_def
    run_next_peer_for_spec
  end

  private def run_flags_peer_for_spec
    self.class.run_flags_peer_for_spec
  end

  private def run_next_peer_for_spec
    self.class.run_next_peer_for_spec
  end

  protected def self.run_flags_peer_for_spec
    if hook = ChunkFieldRaceSpec.before_flags
      ChunkFieldRaceSpec.before_flags = nil
      hook.call
    end
  end

  protected def self.run_next_peer_for_spec
    if hook = ChunkFieldRaceSpec.before_next
      ChunkFieldRaceSpec.before_next = nil
      hook.call
    end
  end
end

class Gcry::Heap
  def unlink_for_field_race_spec(chunk : ChunkHeader*)
    unlink_chunk(chunk)
  end
end

describe "chunk fields updated under different locks" do
  {% for flag in %w[dormant cursor pinned idle holed sparse] %}
    it "does not restore an unlinked next pointer when setting {{flag.id}}" do
      old_next = Pointer(Gcry::ChunkHeader).new(0x1000_u64)
      header = Gcry::ChunkHeader.new(old_next, 4096_u64, 0_u32)
      pointer = pointerof(header)
      ChunkFieldRaceSpec.before_flags = -> {
        pointerof(pointer.value.@next).value = Pointer(Gcry::ChunkHeader).null
        nil
      }
      Gcry::ChunkHeader.set_{{flag.id}}(pointer, true)
      header.next.null?.should be_true
      Gcry::ChunkHeader.{{flag.id}}?(pointer).should be_true
    ensure
      ChunkFieldRaceSpec.before_flags = nil
    end
  {% end %}

  it "preserves a concurrent flag change when unlinking a successor" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      first = heap.malloc(40 * 1024)
      second = heap.malloc(40 * 1024)
      target = (Gcry::BlockHeader.large_header_from_user(first).as(UInt8*) - Gcry::ChunkHeader::SIZE).as(Gcry::ChunkHeader*)
      predecessor = (Gcry::BlockHeader.large_header_from_user(second).as(UInt8*) - Gcry::ChunkHeader::SIZE).as(Gcry::ChunkHeader*)
      ChunkFieldRaceSpec.before_next = -> {
        Gcry::ChunkHeader.set_cursor(predecessor, true)
        nil
      }
      heap.unlink_for_field_race_spec(target)
      Gcry::ChunkHeader.cursor?(predecessor).should be_true
    ensure
      ChunkFieldRaceSpec.before_next = nil
      # The test detached this mapping without freeing it.
      Gcry::OS.munmap(target.as(Void*), LibC::SizeT.new(target.value.mapped_bytes)) if target
      heap.destroy
    end
  end
end
