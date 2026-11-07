require "./spec_helper"

class Gcry::Heap
  # Every instance variable's offset, for the layout example below.
  def self.ivar_offsets_for_spec : Hash(String, UInt64)
    offsets = {} of String => UInt64
    {% for iv in @type.instance_vars %}
      offsets[{{ iv.name.stringify }}] = offsetof(Gcry::Heap, @{{ iv.name }}).to_u64
    {% end %}
    offsets
  end
end

# `src/gcry/heap_hot.cr`: the fields the allocation hit path reads come
# before every other heap field, so a field added anywhere else moves none of
# them. Declared where they are used, as through 0.40, any typed field in an
# earlier file moved them (`bench/log/macos/2026-11-02-intel-binarytrees/`).
describe "heap hot fields" do
  it "sit below every other field" do
    hot = %w(fast_path collecting incremental_marking lazy_sweep_pending
      bytes_since_gc gc_threshold alloc_pfw fast_miss_collecting fast_miss_size
      fast_miss_no_set fast_miss_refill fast_miss_threshold block_bytes
      fit_index fit_payload)
    {% if flag?(:darwin) %}
      hot << "cursor_tsd_slot"
    {% end %}
    offsets = Gcry::Heap.ivar_offsets_for_spec
    hot.each { |name| offsets.has_key?(name).should be_true }
    last_hot = hot.max_of { |name| offsets[name] }
    first_cold = offsets.reject { |name, _| hot.includes?(name) }.values.min
    last_hot.should be < first_cold
  end
end
